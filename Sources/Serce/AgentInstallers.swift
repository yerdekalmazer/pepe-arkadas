import Foundation
import SwiftUI

/// Claude Code dışındaki ajanların hook dosyalarını kurar/kaldırır.
/// Yalnızca Serçe'nin satırlarına dokunur, yazmadan önce `.serce-yedek` alır. `home` testte geçici klasöre çevrilir.
enum AgentInstallers {
    nonisolated(unsafe) static var home = FileManager.default.homeDirectoryForCurrentUser

    enum Style {
        /// {"hooks": {Olay: [{"matcher"?, "hooks": [{"type","command","timeout"}]}]}} — Codex, Gemini
        case grouped(matcher: String?)
        /// {"version": 1, "hooks": {olay: [{"type","bash","timeoutSec"}]}} — Copilot CLI
        case copilot
        /// {"version": 1, "hooks": {olay: [{"command"}]}} — Cursor
        case cursor
    }

    struct Spec {
        let id: String
        let path: String
        let style: Style
        /// (dosyadaki olay adı, zaman aşımı, ek alanlar)
        let events: [(String, Int, [String: Any])]
        /// Ajanın bu Mac'te kurulu olduğunu gösteren yollar (ana klasöre göre ya da mutlak).
        let detect: [String]
        var footer: String
    }

    static let codex = Spec(id: "codex", path: ".codex/hooks.json", style: .grouped(matcher: nil), events: [
        ("SessionStart", 10, [:]), ("UserPromptSubmit", 10, [:]), ("PreToolUse", 10, [:]),
        ("PermissionRequest", 120, ["statusMessage": "Serçe notch'ta cevabını bekliyor"]),
        ("PostToolUse", 10, [:]), ("Stop", 10, [:]), ("SessionEnd", 5, [:]),
    ], detect: [".codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"],
       footer: "~/.codex/hooks.json — izin istekleri notch'ta İzin ver / Reddet olarak gelir.")

    static let gemini = Spec(id: "gemini", path: ".gemini/settings.json", style: .grouped(matcher: "*"), events: [
        ("SessionStart", 10000, [:]), ("SessionEnd", 10000, [:]), ("BeforeTool", 5000, [:]),
        ("AfterTool", 5000, [:]), ("BeforeAgent", 5000, [:]), ("AfterAgent", 5000, [:]),
    ], detect: [".gemini", "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"],
       footer: "~/.gemini/settings.json — oturumlar ve adımlar görünür; izinler Gemini'de kalır.")

    static let copilot = Spec(id: "copilot", path: ".copilot/hooks/serce.json", style: .copilot, events: [
        ("sessionStart", 10, [:]), ("userPromptSubmitted", 10, [:]), ("preToolUse", 10, [:]),
        ("permissionRequest", 120, [:]), ("postToolUse", 10, [:]), ("agentStop", 10, [:]),
        ("sessionEnd", 3, [:]), ("notification", 10, [:]),
    ], detect: [".copilot", "/opt/homebrew/bin/copilot", "/usr/local/bin/copilot"],
       footer: "~/.copilot/hooks/serce.json — izin istekleri notch'ta; Serçe kapalıysa Copilot terminalde sorar.")

    static let cursor = Spec(id: "cursor", path: ".cursor/hooks.json", style: .cursor, events: [
        ("beforeSubmitPrompt", 0, [:]), ("afterFileEdit", 0, [:]), ("afterShellExecution", 0, [:]),
        ("afterAgentResponse", 0, [:]), ("stop", 0, [:]),
    ], detect: [".cursor", "/Applications/Cursor.app"],
       footer: "~/.cursor/hooks.json — Cursor ajanının istemleri, düzenlemeleri ve komutları görünür; onaylar Cursor'da kalır.")

    static let all = [codex, gemini, copilot, cursor]

    static func url(_ spec: Spec) -> URL { home.appendingPathComponent(spec.path) }

    static func command(_ spec: Spec, _ event: String) -> String {
        "'\(Support.hookURL.path)' --agent \(spec.id) \(event)"
    }

    static func isAvailable(_ spec: Spec) -> Bool {
        spec.detect.contains { p in
            FileManager.default.fileExists(atPath: p.hasPrefix("/") ? p : home.appendingPathComponent(p).path)
        }
    }

    static func isInstalled(_ spec: Spec) -> Bool {
        guard let data = try? Data(contentsOf: url(spec)), let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("serce-hook") && s.contains("--agent \(spec.id)")
    }

    static func install(_ spec: Spec) throws {
        var root = try load(spec)
        var hooks = stripped(root["hooks"] as? [String: Any] ?? [:])
        for (event, timeout, extra) in spec.events {
            var list = hooks[event] as? [[String: Any]] ?? []
            switch spec.style {
            case .grouped(let matcher):
                var cmd: [String: Any] = ["type": "command", "command": command(spec, event), "timeout": timeout]
                cmd.merge(extra) { $1 }
                var group: [String: Any] = ["hooks": [cmd]]
                if let matcher { group["matcher"] = matcher }
                list.append(group)
            case .copilot:
                list.append(["type": "command", "bash": command(spec, event), "timeoutSec": timeout])
            case .cursor:
                list.append(["command": command(spec, event)])
            }
            hooks[event] = list
        }
        root["hooks"] = hooks
        if case .grouped = spec.style {} else { root["version"] = root["version"] ?? 1 }
        try save(spec, root)
    }

    static func uninstall(_ spec: Spec) throws {
        guard FileManager.default.fileExists(atPath: url(spec).path) else { return }
        var root = try load(spec)
        let hooks = stripped(root["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try save(spec, root)
    }

    // MARK: -

    private static func load(_ spec: Spec) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url(spec)), !data.isEmpty else { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NSError(domain: "Serce", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/\(spec.path) okunamadı (geçersiz JSON). Dosyaya dokunulmadı."])
        }
        if let h = obj["hooks"], !(h is [String: Any]) {
            throw NSError(domain: "Serce", code: 2, userInfo: [NSLocalizedDescriptionKey: "~/\(spec.path): \"hooks\" beklenmedik biçimde. Dosyaya dokunulmadı."])
        }
        return obj
    }

    private static func save(_ spec: Spec, _ root: [String: Any]) throws {
        let fm = FileManager.default
        let u = url(spec)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = URL(fileURLWithPath: u.path + ".serce-yedek")
        if fm.fileExists(atPath: u.path) {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: u, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: u, options: .atomic)
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        for k in ["command", "bash"] where (entry[k] as? String)?.contains("serce-hook") == true { return true }
        return false
    }

    /// Serçe girdilerini çıkarır; boş kalan grup ve olayları siler, başkalarına dokunmaz.
    private static func stripped(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { out[event] = value; continue }
            let kept: [[String: Any]] = list.compactMap { g in
                if isOurs(g) { return nil }
                guard let inner = g["hooks"] as? [[String: Any]] else { return g }
                let rest = inner.filter { !isOurs($0) }
                if rest.count == inner.count { return g }
                if rest.isEmpty { return nil }
                var g = g
                g["hooks"] = rest
                return g
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }
}

/// OpenCode: hook dosyası yerine küçük bir JS eklentisi. Olayları Serçe'ye iletir, OpenCode'u hiç bekletmez.
enum OpenCodePlugin {
    static var url: URL { AgentInstallers.home.appendingPathComponent(".config/opencode/plugins/serce.js") }
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: AgentInstallers.home.appendingPathComponent(".config/opencode").path)
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/opencode")
    }
    static var isInstalled: Bool { (try? String(contentsOf: url, encoding: .utf8))?.contains("serce") == true }

    static func install() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        if isInstalled { try FileManager.default.removeItem(at: url) }
    }

    static var source: String {
        """
        // Serçe — OpenCode olaylarını notch'a iletir. Serçe ayarlarından kaldırılabilir.
        import { readFileSync } from "fs"
        import { homedir } from "os"

        const URL_BASE = "http://127.0.0.1:\(Support.port)/hook?agent=opencode&event="
        const token = () => { try { return readFileSync(homedir() + "/Library/Application Support/Serce/token", "utf8").trim() } catch { return "" } }
        const send = (event, body) => fetch(URL_BASE + event, {
          method: "POST", headers: { "X-Serce-Token": token(), "Content-Type": "application/json" },
          body: JSON.stringify({ ...body, serce_agent: "opencode" }), signal: AbortSignal.timeout(800),
        }).catch(() => {})

        export const Serce = async ({ directory }) => ({
          event: async ({ event }) => {
            const sid = event.properties?.sessionID ?? event.properties?.info?.id ?? "opencode"
            const map = { "session.created": "SessionStart", "session.idle": "Stop", "session.deleted": "SessionEnd" }
            if (map[event.type]) send(map[event.type], { session_id: sid, cwd: directory })
          },
          "chat.message": async (input) => send("UserPromptSubmit", { session_id: input.sessionID, cwd: directory }),
          "tool.execute.before": async (input, output) =>
            send("PreToolUse", { session_id: input.sessionID, cwd: directory, tool_name: input.tool, tool_input: output.args }),
          "tool.execute.after": async (input, output) =>
            send("PostToolUse", { session_id: input.sessionID, cwd: directory, tool_name: input.tool, tool_response: output.output ?? "" }),
        })

        """
    }
}

// MARK: - Ayarlar satırı

struct AgentInstallRow: View {
    let available: () -> Bool
    let installed: () -> Bool
    let install: () throws -> Void
    let uninstall: () throws -> Void
    @State private var isOn = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle").foregroundStyle(isOn ? .green : .secondary)
                Text(isOn ? "Bağlı" : (available() ? "Bağlı değil" : "Bu Mac'te bulunamadı"))
                Spacer()
                Button(isOn ? "Bağlantıyı kaldır" : "Bağla") {
                    do {
                        if isOn { try uninstall() } else { try install() }
                        error = nil
                    } catch let e { error = e.localizedDescription }
                    isOn = installed()
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { isOn = installed() }
    }
}

enum AgentFeatures {
    @MainActor static func register(_ app: AppState) {
        for spec in AgentInstallers.all {
            AgentRegistry.shared.add(AgentEntry(id: spec.id, name: AgentCatalog.name(spec.id), footer: spec.footer) {
                AnyView(AgentInstallRow(available: { AgentInstallers.isAvailable(spec) },
                                        installed: { AgentInstallers.isInstalled(spec) },
                                        install: { try AgentInstallers.install(spec) },
                                        uninstall: { try AgentInstallers.uninstall(spec) }))
            })
        }
        AgentRegistry.shared.add(AgentEntry(id: "opencode", name: "OpenCode",
                                            footer: "~/.config/opencode/plugins/serce.js — olayları notch'a ileten eklenti.") {
            AnyView(AgentInstallRow(available: { OpenCodePlugin.isAvailable }, installed: { OpenCodePlugin.isInstalled },
                                    install: { try OpenCodePlugin.install() }, uninstall: { try OpenCodePlugin.uninstall() }))
        })
        AgentRegistry.shared.add(AgentEntry(id: "diger", name: "Diğer ajanlar",
                                            footer: "Herhangi bir araç, hook komutu olarak serce-hook'u --agent ile çağırarak kendi adıyla görünür. Yükte serce_agent alanı da kullanılabilir (küçük harf, rakam, tire; en fazla 24).") {
            AnyView(Text("'\(Support.hookURL.path)' --agent araç-adı OlayAdı")
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled))
        })
        PlanFeatures.register(app)
        RecapStore.shared.registerSettings()
        HookInstaller.upgradeIfNeeded()
    }
}
