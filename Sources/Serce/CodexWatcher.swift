import SwiftUI

/// Codex her konuşmayı ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl dosyasına satır satır yazar. Pepe bu dosyaları izler:
/// terminalden, Codex uygulamasından ya da başka bir araçtan açılmış her Codex oturumu çentikte görünür; hook onayı gerekmez.
/// Pepe'nin kendi yürüttüğü çalıştırmalar zaten akıştan okunur, onlar burada atlanır.
@MainActor final class CodexWatcher {
    static let shared = CodexWatcher()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "codexKayitIzle") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "codexKayitIzle")
            newValue ? start() : stop()
        }
    }

    private struct FileState {
        var offset: UInt64 = 0
        var pending = Data()
        var sessionId: String?
        var cwd = ""
        var lastText = ""
    }

    private var files: [String: FileState] = [:]
    private var timer: Timer?
    private var firstScan = true
    /// Son 3 saatte yazılan dosyalar; daha eskisi oturum listesinden de düşer (SessionStore.prune).
    private let window: TimeInterval = 3 * 3600
    private var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions") }

    func start() {
        guard enabled, timer == nil else { return }
        firstScan = true
        scan()
        // Birkaç dosyanın boyutuna bakmak ucuz; boşta işlemciyi yormaz.
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            Task { @MainActor in CodexWatcher.shared.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        let fm = FileManager.default
        let cal = Calendar.current
        let now = Date()
        // Bugün ve dün (gece yarısını geçen oturumlar).
        let dirs = [now, now.addingTimeInterval(-86_400)].map { d -> URL in
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
        }
        let replay = firstScan
        firstScan = false
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let path = dir.appendingPathComponent(name).path
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = (attrs[.size] as? NSNumber)?.uint64Value,
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if files[path] == nil {
                    if now.timeIntervalSince(mtime) > window { files[path] = FileState(offset: size); continue }
                    files[path] = FileState()
                }
                guard let st = files[path], size > st.offset else { continue }
                read(path, upTo: size, quiet: replay)
            }
        }
    }

    private func read(_ path: String, upTo size: UInt64, quiet: Bool) {
        guard var st = files[path], let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: st.offset)
        guard let data = try? h.read(upToCount: Int(min(size - st.offset, 64 << 20))) else { return }
        st.offset += UInt64(data.count)
        st.pending.append(data)
        var lines: [Data] = []
        while let nl = st.pending.firstIndex(of: 0x0A) {
            lines.append(st.pending[st.pending.startIndex..<nl])
            st.pending.removeSubrange(st.pending.startIndex...nl)
        }
        files[path] = st
        let store = AppState.shared.store
        // Açılışta geçmişi sessizce yükle: eski "bitti"ler havlamasın.
        store.replaying = quiet
        defer { store.replaying = false }
        for l in lines where !l.isEmpty { handle(Data(l), path: path) }
    }

    private func handle(_ line: Data, path: String) {
        guard let e = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = e["type"] as? String, let p = e["payload"] as? [String: Any] else { return }
        if type == "session_meta" {
            let cwd = p["cwd"] as? String ?? ""
            // Klasörü silinmiş (geçici) oturumlar gösterilmez.
            guard FileManager.default.fileExists(atPath: cwd) else { return }
            files[path]?.sessionId = p["id"] as? String ?? p["session_id"] as? String
            files[path]?.cwd = cwd
            return
        }
        guard type == "event_msg", let st = files[path], let sid = st.sessionId else { return }
        // Pepe'nin kendi çalıştırması: olaylar zaten akıştan geliyor.
        if AgentRunner.shared.isStreaming(sid) { return }
        switch p["type"] as? String {
        case "item_completed":
            guard let item = p["item"] as? [String: Any] else { return }
            completed(item, sid: sid, cwd: st.cwd, path: path)
        case "task_complete":
            let text = p["last_agent_message"] as? String ?? st.lastText
            emit("Stop", ["last_assistant_message": text], sid: sid, cwd: st.cwd)
        case "turn_aborted":
            AppState.shared.store.markStopped(sid)
        default:
            break
        }
    }

    private func completed(_ item: [String: Any], sid: String, cwd: String, path: String) {
        switch item["type"] as? String {
        case "UserMessage":
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            emit("UserPromptSubmit", ["prompt": text], sid: sid, cwd: cwd)
        case "AgentMessage":
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { files[path]?.lastText = text }
        case "CommandExecution":
            let cmd: String
            if let parts = item["command"] as? [String] {
                cmd = parts.count >= 3 && parts[parts.count - 2] == "-lc" ? parts.last ?? "" : parts.joined(separator: " ")
            } else {
                cmd = item["command"] as? String ?? ""
            }
            let out = item["aggregated_output"] as? String ?? item["stdout"] as? String ?? ""
            let code = (item["exit_code"] as? Int) ?? Int(item["exit_code"] as? String ?? "") ?? 0
            emit("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": cmd], "tool_response": ["stdout": out, "stderr": ""]],
                 sid: sid, cwd: cwd, failure: code != 0 ? (out.isEmpty ? "Komut başarısız." : out) : nil)
        case "FileChange":
            for (file, change) in item["changes"] as? [String: Any] ?? [:] {
                let c = change as? [String: Any] ?? [:]
                let diff = c["unified_diff"] as? String ?? ""
                if c["type"] as? String == "add" {
                    let content = diff.split(separator: "\n", omittingEmptySubsequences: false)
                        .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.map { String($0.dropFirst()) }.joined(separator: "\n")
                    emit("PostToolUse", ["tool_name": "Write", "tool_input": ["file_path": file, "content": content],
                                         "tool_response": [:] as [String: Any]], sid: sid, cwd: cwd)
                } else {
                    emit("PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": file],
                                         "tool_response": ["structuredPatch": Self.hunks(diff)]], sid: sid, cwd: cwd)
                }
            }
        case "McpToolCall":
            let name = "mcp__\(item["server"] as? String ?? "mcp")__\(item["tool"] as? String ?? "arac")"
            emit("PostToolUse", ["tool_name": name, "tool_input": item["arguments"] as? [String: Any] ?? [:]], sid: sid, cwd: cwd)
        case "WebSearch":
            emit("PostToolUse", ["tool_name": "WebSearch", "tool_input": ["query": item["query"] as? String ?? ""]], sid: sid, cwd: cwd)
        default:
            break
        }
    }

    private func emit(_ name: String, _ payload: [String: Any], sid: String, cwd: String, failure: String? = nil) {
        var p = payload
        p["session_id"] = sid
        p["cwd"] = cwd
        var (event, normalized, agent) = AgentNormalizer.normalize(name: name, payload: p, agentArg: "codex", entry: "")
        if let failure { normalized["tool_response"] = failure }
        _ = AppState.shared.store.handle(HookEvent(name: event, payload: normalized, bundleId: "", term: "", agent: agent))
    }

    /// Codex'in birleşik diff'i → Claude Code'un structuredPatch biçimi (satır numaralı fark görünümü için).
    static func hunks(_ diff: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var cur: [String: Any]?
        var lines: [String] = []
        func flush() { if var c = cur { c["lines"] = lines; out.append(c) }; lines = [] }
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(raw)
            if l.hasPrefix("@@") {
                flush()
                // @@ -a,b +c,d @@
                let nums = l.split(separator: " ").dropFirst().prefix(2).map { s -> (Int, Int) in
                    let parts = s.dropFirst().split(separator: ",").compactMap { Int($0) }
                    return (parts.first ?? 1, parts.count > 1 ? parts[1] : 1)
                }
                let old = nums.first ?? (1, 0), new = nums.count > 1 ? nums[1] : (1, 0)
                cur = ["oldStart": old.0, "oldLines": old.1, "newStart": new.0, "newLines": new.1]
            } else if cur != nil, l.hasPrefix(" ") || l.hasPrefix("+") || l.hasPrefix("-") {
                lines.append(l)
            }
        }
        flush()
        return out
    }
}

enum CodexWatcherFeature {
    @MainActor static func register(_ app: AppState) {
        AgentRegistry.shared.add(AgentEntry(id: "codex-kayit", name: "Codex oturum kayıtları",
                                            footer: "Codex'in ~/.codex/sessions altına yazdığı kayıtlar okunur; terminalden ya da başka bir uygulamadan açılan oturumlar da notch'ta görünür. Hook onayı gerekmez; izin kartları için Codex hook'ları yine gerekir.") {
            AnyView(CodexWatcherSettings())
        })
        CodexWatcher.shared.start()
    }
}

private struct CodexWatcherSettings: View {
    @State private var on = CodexWatcher.shared.enabled
    var body: some View {
        Toggle("Codex oturumlarını kayıtlarından izle", isOn: $on)
            .onChange(of: on) { CodexWatcher.shared.enabled = on }
    }
}
