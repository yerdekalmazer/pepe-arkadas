import Foundation

/// Bir MCP sunucusunun tanımı. Kaynak; Serçe kataloğu, kullanıcının eklediği ya da başka bir uygulamadan
/// (Claude Code, Claude Desktop, Cursor, Codex) okunan yapılandırma olabilir. Gizli değerler diske kopyalanmaz:
/// içe alınanlar her açılışta kendi dosyalarından okunur, Serçe'ninkiler Keychain'de durur.
struct MCPServerConfig: Identifiable, Equatable {
    enum Transport: Equatable {
        case http(url: URL, headers: [String: String])
        case stdio(command: String, args: [String], env: [String: String])
    }

    enum Auth: Equatable {
        /// Kimlik doğrulama yok ya da başlıklar yapılandırmada hazır.
        case none
        /// Keychain'deki bir jeton "Authorization: Bearer" olarak gider.
        case bearer(keychain: String)
        /// GitHub: Keychain'de token yoksa `gh auth token` kullanılır (sıfır kurulum).
        case github
        /// MCP yetkilendirme akışı (OAuth 2.1 + PKCE, dinamik istemci kaydı).
        case oauth
    }

    enum Source: String, CaseIterable {
        case catalog = "Serçe kataloğu"
        case custom = "Senin eklediklerin"
        case claudeCode = "Claude Code"
        case claudeDesktop = "Claude Desktop"
        case cursor = "Cursor"
        case codex = "Codex"
    }

    /// Kalıcı kimlik: kaynak + ad. Açma/kapama ve OAuth jetonu bu anahtarla saklanır.
    var id: String { "\(source.rawValue)/\(name)" }
    var name: String
    var source: Source
    var transport: Transport
    var auth: Auth = .none
    var summary: String = ""
    /// Ayarlarda hiç dokunulmadıysa açık mı başlasın?
    var enabledByDefault = true

    /// Model araç adları için güvenli kısa ad ("github", "linear"…).
    var slug: String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(String(s).prefix(20))
    }

    var transportLabel: String {
        switch transport {
        case .http(let url, _): url.host ?? url.absoluteString
        case .stdio(let cmd, let args, _): ([(cmd as NSString).lastPathComponent] + args.prefix(2)).joined(separator: " ")
        }
    }
}

enum MCPConfigLoader {
    static var home = FileManager.default.homeDirectoryForCurrentUser
    static var customURL: URL { Support.dir.appendingPathComponent("mcp.json") }

    /// Hazır sunucular. GitHub `gh` girişiyle kendiliğinden bağlanır; diğerleri ilk kullanımda tarayıcıda giriş ister.
    static let catalog: [MCPServerConfig] = [
        MCPServerConfig(name: "GitHub", source: .catalog,
                        transport: .http(url: URL(string: "https://api.githubcopilot.com/mcp/")!, headers: [:]),
                        auth: .github, summary: "Repo, issue, PR, Actions, kod arama"),
        MCPServerConfig(name: "Notion", source: .catalog,
                        transport: .http(url: URL(string: "https://mcp.notion.com/mcp")!, headers: [:]),
                        auth: .oauth, summary: "Sayfalar ve veritabanları", enabledByDefault: false),
        MCPServerConfig(name: "Linear", source: .catalog,
                        transport: .http(url: URL(string: "https://mcp.linear.app/mcp")!, headers: [:]),
                        auth: .oauth, summary: "Issue'lar, projeler, döngüler", enabledByDefault: false),
        MCPServerConfig(name: "Sentry", source: .catalog,
                        transport: .http(url: URL(string: "https://mcp.sentry.dev/mcp")!, headers: [:]),
                        auth: .oauth, summary: "Hatalar ve performans", enabledByDefault: false),
        MCPServerConfig(name: "Vercel", source: .catalog,
                        transport: .http(url: URL(string: "https://mcp.vercel.com")!, headers: [:]),
                        auth: .oauth, summary: "Projeler, deploy'lar, loglar", enabledByDefault: false),
        MCPServerConfig(name: "Stripe", source: .catalog,
                        transport: .http(url: URL(string: "https://mcp.stripe.com")!, headers: [:]),
                        auth: .oauth, summary: "Ödemeler, müşteriler, faturalar", enabledByDefault: false),
        MCPServerConfig(name: "Atlassian", source: .catalog,
                        transport: .http(url: URL(string: "https://mcp.atlassian.com/v1/mcp")!, headers: [:]),
                        auth: .oauth, summary: "Jira ve Confluence", enabledByDefault: false),
        MCPServerConfig(name: "Context7", source: .catalog,
                        transport: .http(url: URL(string: "https://mcp.context7.com/mcp")!, headers: [:]),
                        auth: .none, summary: "Güncel kütüphane dokümantasyonu", enabledByDefault: false),
    ]

    static func loadAll() -> [MCPServerConfig] {
        var out = catalog
        out += loadCustom()
        out += fromJSON(home.appendingPathComponent(".claude.json"), source: .claudeCode)
        out += fromJSON(home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"), source: .claudeDesktop)
        out += fromJSON(home.appendingPathComponent(".cursor/mcp.json"), source: .cursor)
        out += fromCodexTOML(home.appendingPathComponent(".codex/config.toml"))
        // Aynı adresi gösteren kopyaları ele: katalogdaki ilk kazanır.
        var seen = Set<String>()
        return out.filter { seen.insert(key($0)).inserted }
    }

    private static func key(_ c: MCPServerConfig) -> String {
        switch c.transport {
        case .http(let url, _): url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case .stdio(let cmd, let args, _): ([cmd] + args).joined(separator: " ")
        }
    }

    // MARK: - Kaynaklar

    /// `mcpServers` biçimi (Claude Code, Claude Desktop, Cursor ve Serçe'nin kendi dosyası).
    static func fromJSON(_ url: URL, source: MCPServerConfig.Source) -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        return servers.sorted { $0.key < $1.key }.compactMap { name, value in
            guard let c = value as? [String: Any] else { return nil }
            return parseEntry(name: name, c, source: source)
        }
    }

    static func parseEntry(name: String, _ c: [String: Any], source: MCPServerConfig.Source) -> MCPServerConfig? {
        let env = (c["env"] as? [String: String] ?? [:]).mapValues(expand)
        let headers = (c["headers"] as? [String: String] ?? [:]).mapValues(expand)
        let type = (c["type"] as? String ?? "").lowercased()
        if let urlString = c["url"] as? String, let url = URL(string: expand(urlString)), type != "stdio" {
            // Başlıkta Authorization yoksa sunucu OAuth isteyebilir; 401 gelirse akış başlar.
            let auth: MCPServerConfig.Auth = headers.keys.contains { $0.lowercased() == "authorization" } ? .none : .oauth
            if type == "sse" {
                return MCPServerConfig(name: name, source: source, transport: .http(url: url, headers: headers), auth: auth,
                                       summary: "Eski SSE sunucusu (yalnızca Streamable HTTP destekleniyor)")
            }
            return MCPServerConfig(name: name, source: source, transport: .http(url: url, headers: headers), auth: auth)
        }
        if let cmd = c["command"] as? String {
            let args = (c["args"] as? [String] ?? []).map(expand)
            let command = expand(cmd)
            // Başka bir uygulamanın paketindeki iç araçlar (ör. ChatGPT'nin node_repl'i) kendiliğinden başlatılmaz.
            let insideApp = command.contains(".app/Contents/")
            return MCPServerConfig(name: name, source: source, transport: .stdio(command: command, args: args, env: env),
                                   summary: insideApp ? "Başka bir uygulamanın iç aracı" : "", enabledByDefault: !insideApp)
        }
        return nil
    }

    /// Codex: `[mcp_servers.ad]` bölümleri (command, args, url, env). Yalnızca ihtiyacımız olan TOML alt kümesi.
    static func fromCodexTOML(_ url: URL) -> [MCPServerConfig] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var tables: [String: [String: Any]] = [:]
        var order: [String] = []
        var current: (name: String, isEnv: Bool)?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                guard header.hasPrefix("mcp_servers.") else { current = nil; continue }
                var parts = String(header.dropFirst("mcp_servers.".count)).components(separatedBy: ".")
                let isEnv = parts.count > 1 && parts.last == "env"
                if isEnv { parts.removeLast() }
                let name = parts.joined(separator: ".").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if tables[name] == nil { tables[name] = [:]; order.append(name) }
                current = (name, isEnv)
                continue
            }
            guard let cur = current, let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let v = tomlValue(String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            if cur.isEnv {
                var env = tables[cur.name]?["env"] as? [String: String] ?? [:]
                env[k] = v as? String ?? ""
                tables[cur.name]?["env"] = env
            } else {
                tables[cur.name]?[k] = v
            }
        }
        return order.compactMap { name in
            guard let t = tables[name], (t["enabled"] as? Bool) != false else { return nil }
            var entry = t
            if entry["url"] == nil, entry["command"] == nil { return nil }
            if let bearerEnv = t["bearer_token_env_var"] as? String {
                entry["headers"] = ["Authorization": "Bearer ${\(bearerEnv)}"]
            }
            return parseEntry(name: name, entry, source: .codex)
        }
    }

    private static func tomlValue(_ s: String) -> Any {
        if s.hasPrefix("\"") { return String(s.dropFirst().prefix { $0 != "\"" }) }
        if s.hasPrefix("'") { return String(s.dropFirst().prefix { $0 != "'" }) }
        if s.hasPrefix("[") {
            let inner = s.dropFirst().prefix { $0 != "]" }
            return inner.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }.filter { !$0.isEmpty }
        }
        if s == "true" { return true }
        if s == "false" { return false }
        return s
    }

    /// `${VAR}` ve `${VAR:-varsayılan}` açılımı (Claude Code ile aynı kural).
    static func expand(_ s: String) -> String {
        guard s.contains("${") else { return s }
        var out = "", rest = Substring(s)
        while let start = rest.range(of: "${") {
            out += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else { out += rest[start.lowerBound...]; return out }
            let body = String(rest[start.upperBound..<end])
            let parts = body.components(separatedBy: ":-")
            out += ProcessInfo.processInfo.environment[parts[0]] ?? (parts.count > 1 ? parts[1] : "")
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    // MARK: - Serçe'nin kendi listesi

    static func loadCustom() -> [MCPServerConfig] {
        fromJSON(customURL, source: .custom).map { c in
            var c = c
            if case .http = c.transport, Keychain.get("mcp.bearer.\(c.name)") != nil { c.auth = .bearer(keychain: "mcp.bearer.\(c.name)") }
            return c
        }
    }

    /// Kullanıcının eklediği sunucuyu ~/Library/Application Support/Serce/mcp.json'a yazar (jeton Keychain'e).
    static func saveCustom(name: String, url: String?, command: String?, args: [String], token: String?) throws {
        var root = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: customURL))) as? [String: Any]) ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let url, !url.isEmpty { servers[name] = ["type": "http", "url": url] }
        else if let command, !command.isEmpty { servers[name] = ["command": command, "args": args] }
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: customURL, options: .atomic)
        if let token, !token.isEmpty { Keychain.set("mcp.bearer.\(name)", token) }
    }

    static func removeCustom(name: String) {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: customURL))) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any] else { return }
        servers.removeValue(forKey: name)
        root["mcpServers"] = servers
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: customURL, options: .atomic)
        }
        Keychain.set("mcp.bearer.\(name)", nil)
    }
}

/// `gh` CLI girişinden GitHub jetonu. Uygulama kendi PATH'i olmadan açıldığı için bilinen yerlerde arar.
enum GhCLI {
    private static var cached: (token: String?, at: Date)?

    static var path: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func token() -> String? {
        if let c = cached, Date().timeIntervalSince(c.at) < 600 { return c.token }
        guard let gh = path else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["auth", "token"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let t = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (p.terminationStatus == 0 && !(t ?? "").isEmpty) ? t : nil
        cached = (token, Date())
        return token
    }
}
