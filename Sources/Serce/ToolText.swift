import Foundation

/// Claude Code araç çağrılarını notch'a sığacak kısa Türkçe satırlara çevirir.
enum ToolText {
    static func action(_ tool: String, _ input: [String: Any]) -> String {
        let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        switch tool {
        case "Bash":
            return "$ " + firstLine(input["command"] as? String ?? "", max: 70)
        case "Edit":
            let (a, r) = diffCounts(input["old_string"] as? String, input["new_string"] as? String)
            return "Düzenliyor · \(file)  +\(a) −\(r)"
        case "MultiEdit":
            return "Düzenliyor · \(file)"
        case "Write":
            return "Yazıyor · \(file)"
        case "Read":
            return "Okuyor · \(file)"
        case "NotebookEdit":
            return "Not defteri · \(file)"
        case "Grep":
            return "Arıyor · " + firstLine(input["pattern"] as? String ?? "", max: 50)
        case "Glob":
            return "Dosya arıyor · " + (input["pattern"] as? String ?? "")
        case "WebFetch":
            return "Web · " + (URL(string: input["url"] as? String ?? "")?.host ?? "")
        case "WebSearch":
            return "Web'de arıyor · " + firstLine(input["query"] as? String ?? "", max: 50)
        case "Task", "Agent":
            return "Alt ajan · " + firstLine(input["description"] as? String ?? "", max: 50)
        case "TodoWrite":
            return "Planı güncelliyor"
        case "AskUserQuestion":
            return "Sana soru soruyor"
        default:
            if tool.hasPrefix("mcp__") {
                let p = tool.split(separator: "_", omittingEmptySubsequences: true)
                if p.count >= 3 { return "\(p[1]) · \(p[2...].joined(separator: "_"))" }
            }
            return tool
        }
    }

    static func permissionTitle(_ tool: String) -> String {
        switch tool {
        case "Bash": return "komut çalıştırmak istiyor"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "dosya değiştirmek istiyor"
        case "WebFetch", "WebSearch": return "web'e çıkmak istiyor"
        default: return "\(action(tool, [:])) kullanmak istiyor"
        }
    }

    static func detail(_ tool: String, _ input: [String: Any]) -> String {
        let path = input["file_path"] as? String ?? ""
        switch tool {
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            let desc = input["description"] as? String
            return clip(cmd, lines: 6) + (desc.map { "\n# \($0)" } ?? "")
        case "Edit":
            let old = clip(input["old_string"] as? String ?? "", lines: 3).split(separator: "\n", omittingEmptySubsequences: false).map { "− " + $0 }
            let new = clip(input["new_string"] as? String ?? "", lines: 3).split(separator: "\n", omittingEmptySubsequences: false).map { "+ " + $0 }
            return ([shortPath(path)] + old + new).joined(separator: "\n")
        case "Write":
            return shortPath(path) + "\n" + clip(input["content"] as? String ?? "", lines: 4)
        case "WebFetch":
            return input["url"] as? String ?? ""
        default:
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return clip(String(data: data, encoding: .utf8) ?? "", lines: 6)
        }
    }

    /// Aynı araç çağrısını iki olayda eşlemek için girdinin kararlı bir özeti.
    static func key(_ tool: String, _ input: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        return tool + "|" + (String(data: data, encoding: .utf8) ?? "")
    }

    private static func diffCounts(_ old: String?, _ new: String?) -> (Int, Int) {
        func n(_ s: String?) -> Int { (s?.isEmpty ?? true) ? 0 : s!.split(separator: "\n", omittingEmptySubsequences: false).count }
        return (n(new), n(old))
    }

    private static func firstLine(_ s: String, max: Int) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? ""
        return line.count > max ? String(line.prefix(max)) + "…" : line
    }

    private static func clip(_ s: String, lines: Int) -> String {
        let all = s.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = all.prefix(lines).map { $0.count > 120 ? $0.prefix(120) + "…" : $0 }
        return kept.joined(separator: "\n") + (all.count > lines ? "\n…" : "")
    }

    private static func shortPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
