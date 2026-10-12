import Foundation

/// Claude Code oturum dökümünden (transcript_path, JSONL) okunur konuşma geçmişi:
/// kullanıcının mesajları, Claude'un cevapları ve aradaki araç adımları. Düşünme blokları, sistem notları,
/// yan ajanlar ve araç sonuçları atlanır. Dosyalar büyük olabildiği için yalnızca sondan okunur.
struct HistoryItem: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant, tools }
    let id: Int
    let kind: Kind
    var text: String
    var time: Date?
}

enum TranscriptReader {
    /// Dosyanın son `bytes` kadarını okuyup ayrıştırır. `truncated`: daha eski kayıt var mı.
    /// Dosyanın son `bytes` kadarı (ilk yarım satır atılmış) ve öncesinde kayıt kalıp kalmadığı.
    private static func tail(_ path: String, _ bytes: Int) -> (Data, Bool)? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard var data = try? h.readToEnd() else { return nil }
        if start > 0, let nl = data.firstIndex(of: 0x0A) { data = data[(nl + 1)...] }
        return (data, start > 0)
    }

    struct Command: Identifiable {
        let id: String
        let command: String
        var output = ""
        var isError = false
        var time: Date?
        var running = true
    }

    /// Oturumdaki Bash komutları ve çıktıları (tool_use ↔ tool_result kimlikle eşlenir).
    static func commands(path: String, bytes: Int) -> (items: [Command], truncated: Bool) {
        guard let (data, truncated) = tail(path, bytes) else { return ([], false) }
        var list: [Command] = []
        var index: [String: Int] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: 0x0A) {
            guard line.count > 2, let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  (d["isSidechain"] as? Bool) != true,
                  let blocks = (d["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let time = (d["timestamp"] as? String).flatMap { iso.date(from: $0) }
            for b in blocks {
                switch b["type"] as? String {
                case "tool_use" where b["name"] as? String == "Bash":
                    let id = b["id"] as? String ?? UUID().uuidString
                    let cmd = (b["input"] as? [String: Any])?["command"] as? String ?? ""
                    index[id] = list.count
                    list.append(Command(id: id, command: cmd, time: time))
                case "tool_result":
                    guard let id = b["tool_use_id"] as? String, let i = index[id] else { continue }
                    var out = ""
                    if let s = b["content"] as? String { out = s }
                    else if let parts = b["content"] as? [[String: Any]] {
                        out = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                    }
                    // Çok uzun çıktıların sonu gösterilir.
                    if out.count > 6000 { out = "…\n" + String(out.suffix(6000)) }
                    list[i].output = out
                    list[i].isError = b["is_error"] as? Bool ?? false
                    list[i].running = false
                default:
                    break
                }
            }
        }
        return (Array(list.suffix(150)), truncated)
    }

    static func read(path: String, bytes: Int, includeTools: Bool = false) -> (items: [HistoryItem], truncated: Bool) {
        guard let (data, truncated) = tail(path, bytes) else { return ([], false) }
        let start: UInt64 = truncated ? 1 : 0

        var items: [HistoryItem] = []
        var pendingTools: [String] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            let shown = pendingTools.suffix(3).joined(separator: " · ")
            let more = pendingTools.count > 3 ? "  +\(pendingTools.count - 3) adım" : ""
            items.append(HistoryItem(id: items.count, kind: .tools, text: shown + more, time: nil))
            pendingTools = []
        }

        for line in data.split(separator: 0x0A) {
            guard line.count > 2, let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = d["type"] as? String, type == "user" || type == "assistant",
                  (d["isSidechain"] as? Bool) != true, (d["isMeta"] as? Bool) != true,
                  let message = d["message"] as? [String: Any] else { continue }
            let time = (d["timestamp"] as? String).flatMap { iso.date(from: $0) }

            if type == "user" {
                var text = ""
                if let s = message["content"] as? String {
                    text = s
                } else if let blocks = message["content"] as? [[String: Any]] {
                    // Yalnızca araç sonucu taşıyan kullanıcı satırları konuşma değildir.
                    guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { continue }
                    text = blocks.compactMap { b -> String? in
                        switch b["type"] as? String {
                        case "text": b["text"] as? String
                        case "image": "[görsel]"
                        default: nil
                        }
                    }.joined(separator: "\n")
                }
                text = clean(text)
                guard !text.isEmpty else { continue }
                flushTools()
                items.append(HistoryItem(id: items.count, kind: .user, text: text, time: time))
            } else {
                for b in message["content"] as? [[String: Any]] ?? [] {
                    switch b["type"] as? String {
                    case "text":
                        let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { continue }
                        flushTools()
                        // Aynı turdaki ardışık metinler birleşir.
                        if let last = items.last, last.kind == .assistant {
                            items[items.count - 1].text += "\n\n" + t
                        } else {
                            items.append(HistoryItem(id: items.count, kind: .assistant, text: t, time: time))
                        }
                    case "tool_use":
                        // Araç adımları "Komutlar" sayfasında; geçmişte yalnızca konuşma kalır.
                        if includeTools {
                            let name = b["name"] as? String ?? ""
                            pendingTools.append(ToolText.action(name, b["input"] as? [String: Any] ?? [:]))
                        }
                    default:
                        break
                    }
                }
            }
        }
        flushTools()
        return (Array(items.suffix(300)), start > 0)
    }

    /// Komut sarmalayıcıları ve sistem notları ayıklanır; /komutlar okunur hale gelir.
    static func clean(_ raw: String) -> String {
        var s = raw
        for tag in ["system-reminder", "local-command-stdout", "local-command-stderr", "command-message", "local-command-caveat"] {
            while let a = s.range(of: "<\(tag)>"), let b = s.range(of: "</\(tag)>", range: a.upperBound..<s.endIndex) {
                s.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        if let a = s.range(of: "<command-name>"), let b = s.range(of: "</command-name>") , a.upperBound <= b.lowerBound {
            let name = String(s[a.upperBound..<b.lowerBound])
            var args = ""
            if let c = s.range(of: "<command-args>"), let e = s.range(of: "</command-args>"), c.upperBound <= e.lowerBound {
                args = String(s[c.upperBound..<e.lowerBound])
            }
            s = (name + " " + args).trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
