import Foundation

struct CodeLine: Hashable {
    enum Kind { case context, added, removed }
    var number: Int?
    var text: String
    var kind: Kind = .context
}

enum StepContent {
    case code([CodeLine])
    case terminal(command: String, output: String, failed: Bool)
    case text(String)
}

enum StepStatus { case running, waiting, done, failed }

/// Bir oturumdaki tek araç çağrısı: adım listesinde bir satır, görüntüleyicide bir sayfa.
struct Step: Identifiable {
    let id = UUID()
    let tool: String
    let key: String
    var title: String
    var subtitle: String
    var path: String?
    var status: StepStatus = .running
    var content: StepContent

    var icon: String {
        switch tool {
        case "Read": "doc.text"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Write": "square.and.pencil"
        case "Bash": "terminal"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        default: tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

/// Hook girdilerinden adım üretir. PreToolUse taslağı kurar, PostToolUse gerçek sonuçla (satır numaralı diff, çıktı) doldurur.
enum StepBuilder {
    static let maxLines = 300

    static func pre(_ tool: String, _ input: [String: Any]) -> Step {
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String
        let key = ToolText.key(tool, input)
        var step = Step(tool: tool, key: key, title: title(tool), subtitle: "", path: path, content: .text(""))
        switch tool {
        case "Read":
            step.subtitle = short(path)
            step.content = .text("Okunuyor…")
        case "Edit":
            step.subtitle = short(path)
            step.content = .code(naiveDiff(input["old_string"] as? String ?? "", input["new_string"] as? String ?? ""))
        case "MultiEdit":
            step.subtitle = short(path)
            let edits = input["edits"] as? [[String: Any]] ?? []
            step.content = .code(edits.flatMap { naiveDiff($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") })
        case "Write":
            step.subtitle = short(path)
            step.content = .code(numbered(input["content"] as? String ?? "", from: 1, kind: .added))
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            step.subtitle = firstLine(cmd)
            step.content = .terminal(command: cmd, output: "", failed: false)
        default:
            step.subtitle = ToolText.action(tool, input)
            step.content = .text(ToolText.detail(tool, input))
        }
        return step
    }

    static func post(_ step: inout Step, _ response: Any?) {
        step.status = .done
        let r = response as? [String: Any]
        switch step.tool {
        case "Read":
            if let file = r?["file"] as? [String: Any], let text = file["content"] as? String {
                step.content = .code(numbered(text, from: file["startLine"] as? Int ?? 1, kind: .context))
            } else {
                step.content = .text("Dosya okundu.")
            }
        case "Edit", "MultiEdit":
            if let patch = r?["structuredPatch"] as? [[String: Any]], !patch.isEmpty {
                step.content = .code(fromPatch(patch))
            }
        case "Bash":
            guard case .terminal(let cmd, _, _) = step.content else { return }
            if let r {
                let out = [r["stdout"] as? String ?? "", r["stderr"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
                let failed = (r["interrupted"] as? Bool ?? false)
                step.content = .terminal(command: cmd, output: clip(out), failed: failed)
            } else if let s = response as? String {
                step.content = .terminal(command: cmd, output: clip(s), failed: true)
                step.status = .failed
            }
        case "Grep", "Glob":
            if let names = r?["filenames"] as? [String], !names.isEmpty {
                step.content = .text(clip(names.map(short).joined(separator: "\n")))
            } else if let content = r?["content"] as? String, !content.isEmpty {
                step.content = .text(clip(content))
            } else {
                step.content = .text("Sonuç yok.")
            }
        case "Write":
            break
        default:
            if let s = response as? String { step.content = .text(clip(s)) }
            else if let r, let text = r["result"] as? String ?? r["content"] as? String { step.content = .text(clip(text)) }
        }
    }

    /// Hook'tan önce (izin kartında) gösterilecek önizleme.
    static func preview(_ tool: String, _ input: [String: Any]) -> Step {
        var s = pre(tool, input)
        s.status = .waiting
        if case .text = s.content { s.content = .text(ToolText.detail(tool, input)) }
        return s
    }

    // MARK: -

    private static func title(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let p = tool.split(separator: "_", omittingEmptySubsequences: true)
            return p.count >= 3 ? String(p[2...].joined(separator: "_")) : tool
        }
        return tool == "Task" ? "Agent" : tool
    }

    private static func fromPatch(_ hunks: [[String: Any]]) -> [CodeLine] {
        var out: [CodeLine] = []
        for (i, h) in hunks.enumerated() {
            var old = h["oldStart"] as? Int ?? 1, new = h["newStart"] as? Int ?? 1
            if i > 0 { out.append(CodeLine(number: nil, text: "⋯")) }
            for raw in h["lines"] as? [String] ?? [] {
                let body = String(raw.dropFirst())
                switch raw.first {
                case "-": out.append(CodeLine(number: old, text: body, kind: .removed)); old += 1
                case "+": out.append(CodeLine(number: new, text: body, kind: .added)); new += 1
                default: out.append(CodeLine(number: new, text: body)); old += 1; new += 1
                }
            }
        }
        return Array(out.prefix(maxLines))
    }

    private static func naiveDiff(_ old: String, _ new: String) -> [CodeLine] {
        let o = old.isEmpty ? [] : old.components(separatedBy: "\n").map { CodeLine(number: nil, text: $0, kind: .removed) }
        let n = new.isEmpty ? [] : new.components(separatedBy: "\n").map { CodeLine(number: nil, text: $0, kind: .added) }
        return Array((o + n).prefix(maxLines))
    }

    private static func numbered(_ text: String, from start: Int, kind: CodeLine.Kind) -> [CodeLine] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.prefix(maxLines).enumerated().map { CodeLine(number: start + $0.offset, text: $0.element, kind: kind) }
    }

    static func short(_ p: String?) -> String {
        guard let p else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private static func firstLine(_ s: String) -> String {
        let l = s.split(separator: "\n").first.map(String.init) ?? ""
        return l.count > 60 ? String(l.prefix(60)) + "…" : l
    }

    private static func clip(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        let kept = lines.suffix(maxLines).joined(separator: "\n")
        return kept.count > 20_000 ? String(kept.suffix(20_000)) : kept
    }
}
