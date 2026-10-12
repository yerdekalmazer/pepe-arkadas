import Foundation
import SwiftUI

/// Bilinen ajanlar: görünen ad, renk ve izin yanıtının biçimi.
enum AgentCatalog {
    static let claude = "claude"

    static func name(_ id: String) -> String {
        switch id {
        case "claude", "": "Claude Code"
        case "claude-desktop": "Claude Desktop"
        case "codex": "Codex"
        case "gemini": "Gemini CLI"
        case "copilot": "Copilot CLI"
        case "cursor": "Cursor"
        case "opencode": "OpenCode"
        case "amp": "Amp"
        case "muse": "Muse Code"
        default: id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    static func color(_ id: String) -> Color? {
        switch id {
        case "codex": Color(red: 0.55, green: 0.60, blue: 0.70)
        case "gemini": Color(red: 0.35, green: 0.55, blue: 0.95)
        case "copilot": Color(red: 0.60, green: 0.45, blue: 0.85)
        case "cursor": Color(red: 0.45, green: 0.45, blue: 0.50)
        case "opencode": Color(red: 0.30, green: 0.70, blue: 0.60)
        default: nil
        }
    }

    /// Hook yükündeki `serce_agent` (ya da Coucou uyumlu `coucou_agent`) için izin verilen biçim.
    static func isValid(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 24 && s.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }

    /// Kararın ajanın beklediği JSON'a çevrilmiş hali. Boş metin = "terminalde sor".
    static func permissionOutput(agent: String, decision: Decision, suggestions: [Any]) -> String {
        let obj: [String: Any]?
        switch agent {
        case "copilot", "muse":
            let v: String
            switch decision {
            case .allow, .always: v = "allow"
            case .deny: v = "deny"
            case .terminal: v = "ask"
            }
            obj = ["permissionDecision": v]
        default:
            var d: [String: Any]
            switch decision {
            case .allow: d = ["behavior": "allow"]
            case .always:
                d = ["behavior": "allow"]
                if agent == claude || agent == "claude-desktop", !suggestions.isEmpty { d["updatedPermissions"] = suggestions }
            case .deny: d = ["behavior": "deny", "message": "Serçe'den reddedildi"]
            case .terminal: d = [:]
            }
            obj = d.isEmpty ? nil : ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
        }
        guard let obj, let data = try? JSONSerialization.data(withJSONObject: obj) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Her ajanın kendine özgü olay adlarını ve alanlarını Claude Code'un kanonik biçimine çevirir.
enum AgentNormalizer {
    static let eventMap: [String: String] = [
        // Gemini CLI
        "BeforeTool": "PreToolUse", "AfterTool": "PostToolUse", "BeforeAgent": "UserPromptSubmit", "AfterAgent": "Stop",
        // Copilot CLI
        "sessionStart": "SessionStart", "userPromptSubmitted": "UserPromptSubmit", "preToolUse": "PreToolUse",
        "permissionRequest": "PermissionRequest", "postToolUse": "PostToolUse", "agentStop": "Stop",
        "sessionEnd": "SessionEnd", "notification": "Notification",
        // Cursor
        "beforeSubmitPrompt": "UserPromptSubmit", "afterFileEdit": "PostToolUse", "afterShellExecution": "PostToolUse",
        "afterAgentResponse": "Notification", "stop": "Stop",
        // OpenCode eklentisi ve diğerleri
        "session_start": "SessionStart", "session_end": "SessionEnd", "pre_tool_use": "PreToolUse",
        "post_tool_use": "PostToolUse", "user_prompt_submit": "UserPromptSubmit",
    ]

    static let toolMap: [String: String] = [
        "bash": "Bash", "shell": "Bash", "run_shell_command": "Bash", "edit": "Edit", "replace": "Edit",
        "write": "Write", "write_file": "Write", "read": "Read", "read_file": "Read", "grep": "Grep",
        "search_file_content": "Grep", "glob": "Glob", "webfetch": "WebFetch", "web_fetch": "WebFetch",
        "google_web_search": "WebSearch", "list": "Glob", "list_directory": "Glob", "todowrite": "TodoWrite",
    ]

    static let keyMap: [String: String] = [
        "filePath": "file_path", "oldString": "old_string", "newString": "new_string", "absolute_path": "file_path",
        "old_str": "old_string", "new_str": "new_string",
    ]

    /// (kanonik olay adı, düzeltilmiş yük, ajan kimliği)
    static func normalize(name rawName: String, payload raw: [String: Any], agentArg: String, entry: String) -> (String, [String: Any], String) {
        var p = raw
        var agent = agentArg
        if !AgentCatalog.isValid(agent) {
            agent = (p["serce_agent"] as? String) ?? (p["coucou_agent"] as? String) ?? ""
        }
        if !AgentCatalog.isValid(agent) { agent = entry == "claude-desktop" ? "claude-desktop" : AgentCatalog.claude }

        let original = rawName.isEmpty ? (p["hook_event_name"] as? String ?? "") : rawName
        let name = eventMap[original] ?? original

        // Oturum ve klasör alanları
        if (p["session_id"] as? String ?? "").isEmpty {
            p["session_id"] = (p["sessionId"] as? String) ?? (p["conversation_id"] as? String)
                ?? (p["conversationId"] as? String) ?? "\(agent)-oturum"
        }
        if (p["cwd"] as? String ?? "").isEmpty {
            if let roots = (p["workspace_roots"] ?? p["workspacePaths"]) as? [String], let first = roots.first { p["cwd"] = first }
        }

        // Araç adı ve girdisi
        if p["tool_name"] == nil {
            if let t = p["toolName"] as? String { p["tool_name"] = t }
            else if let call = p["toolCall"] as? [String: Any], let t = call["name"] as? String {
                p["tool_name"] = t
                if p["tool_input"] == nil { p["tool_input"] = call["args"] }
            }
        }
        if p["tool_input"] == nil, let args = p["toolArgs"] {
            if let d = args as? [String: Any] { p["tool_input"] = d }
            else if let s = args as? String, let d = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] { p["tool_input"] = d }
        }

        // Cursor: dosya düzenleme ve kabuk komutu yalnızca "sonra" olayıyla gelir.
        switch original {
        case "afterFileEdit":
            let edits = p["edits"] as? [[String: Any]] ?? []
            p["tool_name"] = "Edit"
            p["tool_input"] = ["file_path": p["file_path"] ?? "",
                               "old_string": edits.compactMap { $0["old_string"] as? String }.joined(separator: "\n"),
                               "new_string": edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n")]
        case "afterShellExecution":
            p["tool_name"] = "Bash"
            p["tool_input"] = ["command": p["command"] ?? ""]
            p["tool_response"] = ["stdout": p["output"] as? String ?? "", "stderr": ""]
        case "afterAgentResponse":
            p["message"] = p["text"] as? String ?? ""
        default:
            break
        }

        if let t = p["tool_name"] as? String, let mapped = toolMap[t] ?? toolMap[t.lowercased()] { p["tool_name"] = mapped }
        if var input = p["tool_input"] as? [String: Any] {
            for (from, to) in keyMap {
                guard let v = input.removeValue(forKey: from) else { continue }
                if input[to] == nil { input[to] = v }
            }
            p["tool_input"] = input
        }
        if let r = p["tool_response"] as? String { p["tool_response"] = ["stdout": r, "stderr": ""] }
        if var r = p["tool_response"] as? [String: Any], r["stdout"] == nil, r["file"] == nil, r["structuredPatch"] == nil,
           let out = (r["llmContent"] ?? r["returnDisplay"] ?? r["output"]) as? String {
            r["stdout"] = out
            r["stderr"] = r["stderr"] ?? ""
            p["tool_response"] = r
        }
        return (name, p, agent)
    }
}
