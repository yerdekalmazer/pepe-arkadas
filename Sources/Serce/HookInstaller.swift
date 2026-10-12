import Foundation

/// ~/.claude/settings.json içine Serçe hook'larını ekler/kaldırır. Diğer hook'lara dokunmaz, yazmadan önce yedek alır.
enum HookInstaller {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "PermissionRequest", "Notification", "Stop", "SessionEnd"]
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PermissionRequest"]
    static let marker = "serce-hook"
    static var settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "~/.claude/settings.json okunamadı (geçersiz JSON). Dosyaya dokunulmadı." }
    }

    static func isInstalled() -> Bool {
        guard let hooks = (try? load())?["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in groups(hooks[ev]).contains(where: isOurs) }
    }

    static func install() throws {
        var root = try load()
        var hooks = stripped(root["hooks"] as? [String: Any] ?? [:])
        for ev in events {
            var cmd: [String: Any] = ["type": "command", "command": "'\(Support.hookURL.path)' \(ev)"]
            cmd["timeout"] = ev == "PermissionRequest" ? 120 : 5
            var group: [String: Any] = ["hooks": [cmd]]
            if toolEvents.contains(ev) { group["matcher"] = "*" }
            hooks[ev] = groups(hooks[ev]) + [group]
        }
        // AskUserQuestion için ayrı, bekleyen PreToolUse hook'u: sorular notch'ta cevaplanır.
        let ask: [String: Any] = ["matcher": "AskUserQuestion",
                                  "hooks": [["type": "command", "command": "'\(Support.hookURL.path)' Ask", "timeout": 130]]]
        hooks["PreToolUse"] = groups(hooks["PreToolUse"]) + [ask]
        root["hooks"] = hooks
        try save(root)
    }

    /// Eski sürümle kurulmuş (soru hook'u eksik) bağlantıyı sessizce tamamlar. Yalnızca Serçe satırlarına dokunur.
    static func upgradeIfNeeded() {
        guard isInstalled(), let hooks = (try? load())?["hooks"] as? [String: Any] else { return }
        let hasAsk = groups(hooks["PreToolUse"]).contains { ($0["matcher"] as? String) == "AskUserQuestion" && isOurs($0) }
        if !hasAsk { try? install() }
    }

    static func uninstall() throws {
        var root = try load()
        let hooks = stripped(root["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try save(root)
    }

    // MARK: -

    private static func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        if data.isEmpty { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unreadable }
        return obj
    }

    private static func save(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = settingsURL.appendingPathExtension("serce-yedek")
        if fm.fileExists(atPath: settingsURL.path) {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func groups(_ v: Any?) -> [[String: Any]] { v as? [[String: Any]] ?? [] }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains(marker) }
    }

    /// Serçe'ye ait komutları çıkarır; boş kalan grupları ve olayları siler.
    private static func stripped(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (ev, value) in hooks {
            guard let list = value as? [[String: Any]] else { out[ev] = value; continue }
            let kept: [[String: Any]] = list.compactMap { g in
                var g = g
                guard let orig = g["hooks"] as? [[String: Any]] else { return g }
                let cmds = orig.filter { !($0["command"] as? String ?? "").contains(marker) }
                if cmds.count == orig.count { return g }
                if cmds.isEmpty { return nil }
                g["hooks"] = cmds
                return g
            }
            if !kept.isEmpty { out[ev] = kept }
        }
        return out
    }
}
