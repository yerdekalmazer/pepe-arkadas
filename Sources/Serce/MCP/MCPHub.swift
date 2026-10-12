import Foundation
import SwiftUI

/// Tüm MCP sunucularının merkezi: yapılandırmaları yükler, bağlanır, araçları toplar,
/// model araç adlarını sunucu/araç çiftine çevirir ve yazma araçları için notch'tan onay ister.
@MainActor final class MCPHub: ObservableObject {
    static let shared = MCPHub()

    enum Status: Equatable {
        case off, connecting, ready(Int), needsAuth, failed(String)
    }

    @Published private(set) var servers: [MCPServerConfig] = []
    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var tools: [String: [MCPTool]] = [:]
    @Published private(set) var signingIn: String?

    private var connections: [String: MCPConnection] = [:]
    private var authChallenges: [String: String] = [:]
    /// Model tarafındaki araç adı → (sunucu kimliği, araç adı).
    private var routes: [String: (String, String)] = [:]

    private var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mcpKapali") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "mcpKapali") }
    }
    private var enabledExplicit: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mcpAcik") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "mcpAcik") }
    }
    /// "Hep izin ver" denmiş araçlar (sunucu/araç).
    private var alwaysAllowed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mcpHepIzin") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "mcpHepIzin") }
    }

    func isEnabled(_ c: MCPServerConfig) -> Bool {
        if disabled.contains(c.id) { return false }
        return c.enabledByDefault || enabledExplicit.contains(c.id)
    }

    var readyCount: Int { status.values.filter { if case .ready = $0 { true } else { false } }.count }
    var toolCount: Int { servers.filter(isEnabled).reduce(0) { $0 + (tools[$1.id]?.count ?? 0) } }

    // MARK: - Yaşam döngüsü

    func reload() {
        servers = MCPConfigLoader.loadAll()
        for c in servers where !isEnabled(c) { status[c.id] = .off }
        Task { await connectAll() }
    }

    func connectAll() async {
        await withTaskGroup(of: Void.self) { g in
            for c in servers where isEnabled(c) {
                if case .ready = status[c.id] ?? .off { continue }
                g.addTask { await self.connect(c) }
            }
        }
    }

    func setEnabled(_ c: MCPServerConfig, _ on: Bool) {
        var d = disabled, e = enabledExplicit
        if on { d.remove(c.id); e.insert(c.id) } else { d.insert(c.id); e.remove(c.id) }
        disabled = d
        enabledExplicit = e
        if on {
            Task { await connect(c) }
        } else {
            Task { await connections[c.id]?.close() }
            connections[c.id] = nil
            tools[c.id] = nil
            status[c.id] = .off
        }
    }

    func connect(_ c: MCPServerConfig) async {
        status[c.id] = .connecting
        if case .github = c.auth, Keychain.get(GitHubPill.keyName) == nil, GhCLI.token() == nil {
            status[c.id] = .failed("GitHub girişi yok: Terminalde `gh auth login` çalıştır ya da Ayarlar'dan token gir.")
            return
        }
        let conn = MCPConnection(config: c, authHeader: Self.authProvider(for: c))
        await connections[c.id]?.close()
        connections[c.id] = conn
        do {
            let list = try await conn.listTools()
            tools[c.id] = list
            status[c.id] = .ready(list.count)
        } catch MCPError.needsAuth(let header) {
            authChallenges[c.id] = header
            tools[c.id] = nil
            status[c.id] = .needsAuth
        } catch {
            tools[c.id] = nil
            status[c.id] = .failed(error.localizedDescription)
        }
    }

    /// OAuth isteyen sunucuya tarayıcıda giriş.
    func signIn(_ c: MCPServerConfig) async {
        guard case .http(let url, _) = c.transport else { return }
        signingIn = c.id
        defer { signingIn = nil }
        do {
            try await MCPOAuth.signIn(serverId: c.id, resource: url, wwwAuthenticate: authChallenges[c.id])
            var e = enabledExplicit
            e.insert(c.id)
            enabledExplicit = e
            disabled.remove(c.id)
            await connect(c)
        } catch {
            status[c.id] = .failed(error.localizedDescription)
        }
    }

    func signOut(_ c: MCPServerConfig) {
        MCPOAuth.signOut(c.id)
        Task { await connections[c.id]?.close() }
        connections[c.id] = nil
        tools[c.id] = nil
        status[c.id] = .needsAuth
    }

    private static func authProvider(for c: MCPServerConfig) -> @Sendable () async -> String? {
        let id = c.id
        switch c.auth {
        case .none: return { nil }
        case .bearer(let key): return { Keychain.get(key).map { "Bearer \($0)" } }
        case .github: return { (Keychain.get("github.token") ?? GhCLI.token()).map { "Bearer \($0)" } }
        case .oauth: return { await MCPOAuth.accessToken(id).map { "Bearer \($0)" } }
        }
    }

    // MARK: - Modele sunulan araçlar

    /// Claude Messages API araç tanımları. Çok sayıda araç varsa hepsi "ertelenmiş" işaretlenir ve
    /// Claude araç aramasıyla ihtiyaç duyduğunu yükler (bağlam şişmesin).
    func claudeTools() -> [[String: Any]] {
        routes = [:]
        var defs: [[String: Any]] = []
        for c in servers where isEnabled(c) {
            for t in tools[c.id] ?? [] {
                var name = "\(c.slug)__\(t.name)".map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
                    .map(String.init).joined()
                if name.count > 64 { name = String(name.prefix(64)) }
                while routes[name] != nil { name = String(name.prefix(60)) + "_\(Int.random(in: 10...99))" }
                routes[name] = (c.id, t.name)
                var schema = t.inputSchema
                if schema["type"] == nil { schema["type"] = "object" }
                defs.append(["name": name,
                             "description": "[\(c.name)] " + String(t.description.prefix(1000)),
                             "input_schema": schema])
            }
        }
        guard defs.count > 12 else { return defs }
        return defs.map { var d = $0; d["defer_loading"] = true; return d }
            + [["type": "tool_search_tool_bm25_20251119", "name": "tool_search_tool_bm25"]]
    }

    func owns(_ toolName: String) -> Bool { routes[toolName] != nil }

    /// Test modu: bağlan, listele, GitHub'da salt okuma bir araç çağır, OAuth sunucularında keşfi dene.
    func selfTest() async {
        servers = MCPConfigLoader.loadAll()
        for c in servers { print("• [\(c.source.rawValue)] \(c.name) — \(c.transportLabel) — \(isEnabled(c) ? "açık" : "kapalı")") }
        for c in servers where isEnabled(c) { await connect(c) }
        for c in servers {
            switch status[c.id] ?? .off {
            case .ready(let n): print("✓ \(c.name): \(n) araç")
            case .needsAuth:
                if case .http(let url, _) = c.transport {
                    print("⚠︎ \(c.name): giriş gerekli — \(await MCPOAuth.probe(resource: url, wwwAuthenticate: authChallenges[c.id]))")
                }
            case .failed(let m): print("✗ \(c.name): \(m)")
            default: break
            }
        }
        for c in servers where c.auth == .oauth && c.source == .catalog && !isEnabled(c) {
            if case .http(let url, _) = c.transport {
                print("  \(c.name) keşif: \(await MCPOAuth.probe(resource: url, wwwAuthenticate: nil))")
            }
        }
        let defs = claudeTools()
        print("Claude'a sunulan tanım: \(defs.count) (ertelenmiş: \(defs.filter { $0["defer_loading"] as? Bool == true }.count))")
        let bad = defs.filter { d in
            guard let n = d["name"] as? String else { return true }
            if d["type"] != nil { return false }
            let okName = n.count <= 64 && n.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            let okSchema = ((d["input_schema"] as? [String: Any])?["type"] as? String) == "object"
            let json = JSONSerialization.isValidJSONObject(d)
            return !(okName && okSchema && json)
        }
        print(bad.isEmpty ? "✓ tüm araç tanımları API biçimine uygun" : "✗ uygunsuz: \(bad.compactMap { $0["name"] })")
        if let gh = routes.first(where: { $0.value.1 == "get_me" })?.key {
            let (text, err, _) = await call(gh, [:], askedBy: "test")
            print(err ? "✗ get_me: \(text.prefix(200))" : "✓ get_me: \(text.prefix(160).replacingOccurrences(of: "\n", with: " "))")
        }
    }

    /// Aracı çalıştırır. Salt okuma işaretli değilse ve daha önce "hep izin ver" denmediyse notch'tan onay ister.
    func call(_ toolName: String, _ input: [String: Any], askedBy: String) async -> (String, Bool, [(String, String)]) {
        guard let (serverId, name) = routes[toolName], let conn = connections[serverId],
              let server = servers.first(where: { $0.id == serverId }) else { return ("Araç bulunamadı.", true, []) }
        let tool = tools[serverId]?.first { $0.name == name }
        let permKey = "\(serverId)/\(name)"
        if !(tool?.readOnly ?? false), !alwaysAllowed.contains(permKey) {
            let decision = await AppState.shared.store.requestLocalApproval(
                project: askedBy, tool: "\(server.name) · \(name)",
                title: "\(server.name) aracını kullanmak istiyor", input: input, allowAlways: true)
            switch decision {
            case .allow: break
            case .always:
                var a = alwaysAllowed
                a.insert(permKey)
                alwaysAllowed = a
            case .deny, .terminal: return ("Kullanıcı bu işlemi reddetti.", true, [])
            }
        }
        do {
            let r = try await conn.call(name, input)
            var text = r.text
            // Bağlamı şişirmesin: büyük çıktılar kesilir (model daha dar bir sorguyla tekrar isteyebilir).
            if text.count > 20_000 { text = String(text.prefix(20_000)) + "\n…(çıktı 20.000 karakterde kesildi; daha dar bir sorgu dene)" }
            return (text.isEmpty ? "(boş sonuç)" : text, r.isError, r.images)
        } catch MCPError.needsAuth {
            status[serverId] = .needsAuth
            return ("\(server.name) için giriş gerekli; Ayarlar → MCP'den bağlanılmalı.", true, [])
        } catch {
            return ("\(server.name) hatası: \(error.localizedDescription)", true, [])
        }
    }
}
