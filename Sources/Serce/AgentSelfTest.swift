import Foundation

/// `Serce --ajan-testi <klasör>`: kurucuları geçici bir ana klasörde çalıştırır, normalleştirme ve
/// yanıt biçimlerini yazdırır. Gerçek ~/.claude, ~/.codex… dosyalarına dokunmaz.
@MainActor enum AgentSelfTest {
    static func run(home: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: home)
        try? fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        AgentInstallers.home = home
        HookInstaller.settingsURL = home.appendingPathComponent(".claude/settings.json")
        StatusLineInstaller.previousURL = home.appendingPathComponent("serce/statusline-previous.json")
        RecapStore.fileURL = home.appendingPathComponent("serce/haftalik.json")

        // Kullanıcının mevcut ayarları ve statusLine'ı varmış gibi
        let existing = #"{"statusLine":{"type":"command","command":"~/.claude/eski-durum.sh","padding":0},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say bitti"}]}]}}"#
        try? existing.write(to: HookInstaller.settingsURL, atomically: true, encoding: .utf8)
        try? #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"baska-arac"}]}]}}"#
            .write(to: home.appendingPathComponent(".codex/hooks.json").creatingParent(), atomically: true, encoding: .utf8)

        func show(_ title: String, _ url: URL) {
            print("── \(title) (\(url.path.replacingOccurrences(of: home.path, with: "~")))")
            print((try? String(contentsOf: url, encoding: .utf8)) ?? "(yok)")
        }

        do {
            try HookInstaller.install()
            try StatusLineInstaller.install()
            for spec in AgentInstallers.all { try AgentInstallers.install(spec) }
            try OpenCodePlugin.install()
        } catch { print("HATA kurulum: \(error)") }

        show("Claude Code settings.json (kurulu)", HookInstaller.settingsURL)
        show("statusline-previous.json", StatusLineInstaller.previousURL)
        for spec in AgentInstallers.all { show(spec.id, AgentInstallers.url(spec)) }
        print("kurulu mu? claude=\(HookInstaller.isInstalled()) statusline=\(StatusLineInstaller.isInstalled()) "
              + AgentInstallers.all.map { "\($0.id)=\(AgentInstallers.isInstalled($0))" }.joined(separator: " ")
              + " opencode=\(OpenCodePlugin.isInstalled)")

        do {
            try HookInstaller.uninstall()
            try StatusLineInstaller.uninstall()
            for spec in AgentInstallers.all { try AgentInstallers.uninstall(spec) }
            try OpenCodePlugin.uninstall()
        } catch { print("HATA kaldırma: \(error)") }
        show("Claude Code settings.json (kaldırıldı)", HookInstaller.settingsURL)
        show("codex (kaldırıldı)", AgentInstallers.url(AgentInstallers.codex))
        show("cursor (kaldırıldı)", AgentInstallers.url(AgentInstallers.cursor))

        print("── normalleştirme")
        let cases: [(String, [String: Any], String)] = [
            ("BeforeTool", ["session_id": "g1", "cwd": "/p/a", "tool_name": "run_shell_command", "tool_input": ["command": "ls"]], "gemini"),
            ("afterShellExecution", ["conversation_id": "c1", "workspace_roots": ["/p/b"], "command": "npm test", "output": "ok"], "cursor"),
            ("afterFileEdit", ["conversation_id": "c1", "file_path": "/p/b/x.ts", "edits": [["old_string": "a", "new_string": "b"]]], "cursor"),
            ("permissionRequest", ["sessionId": "k1", "cwd": "/p/c", "toolName": "bash", "toolArgs": #"{"command":"rm x"}"#], "copilot"),
            ("PreToolUse", ["session_id": "x", "tool_name": "edit", "tool_input": ["filePath": "/a.ts", "oldString": "1", "newString": "2"], "serce_agent": "opencode"], ""),
            ("Stop", ["session_id": "d1"], ""),
        ]
        for (name, payload, agent) in cases {
            let (n, p, a) = AgentNormalizer.normalize(name: name, payload: payload, agentArg: agent, entry: name == "Stop" ? "claude-desktop" : "")
            let pick = ["session_id", "cwd", "tool_name", "tool_input", "tool_response"].compactMap { k in p[k].map { "\(k)=\($0)" } }
            print("\(agent.isEmpty ? "-" : agent) \(name) → \(n) [\(a)] \(pick.joined(separator: " "))")
        }

        print("── izin çıktıları")
        let sug: [Any] = [["type": "addRules", "behavior": "allow", "destination": "localSettings", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]]]]
        for agent in ["claude", "codex", "copilot"] {
            for d in [Decision.allow, .always, .deny, .terminal] {
                print("\(agent) \(d): \(AgentCatalog.permissionOutput(agent: agent, decision: d, suggestions: sug))")
            }
        }

        print("── soru çıktısı")
        let input: [String: Any] = ["questions": [
            ["question": "Hangi veritabanı?", "header": "VT", "multiSelect": false,
             "options": [["label": "Postgres", "description": "İlişkisel"], ["label": "SQLite", "description": "Dosya"]]],
            ["question": "Hangi özellikler?", "header": "Özellik", "multiSelect": true,
             "options": [["label": "Arama"], ["label": "Etiket"], ["label": "Dışa aktarma"]]],
        ]]
        if let items = QuestionItem.parse(input) {
            for f in [QuestionRequest.Format.preToolUse, .permissionRequest] {
                let q = QuestionRequest(sessionId: "s", project: "p", agent: "claude", key: "k", items: items,
                                        rawQuestions: input["questions"] as! [Any], format: f, responder: Responder { _ in })
                print("\(f): \(q.output(selections: [["Postgres"], ["Arama", "Etiket"]]))")
            }
        }
        print("── hook betiği --statusline (önceki komutu çağırıyor mu)")
        print(Support.hookScript.contains("statusline-previous.json") ? "evet" : "HAYIR")
    }
}

private extension URL {
    func creatingParent() -> URL {
        try? FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
