import Foundation

/// Pepe'nin terminalsiz yürütebildiği ajanlar. Claude Code hook'larla, Codex ve Gemini CLI kendi canlı olay akışlarıyla
/// (`codex exec --json`, `gemini -o stream-json`) izlenir; ajan hook'ları güvenilir sayılmasa da kart dolar.
enum RunnableAgent: String, CaseIterable, Identifiable {
    case claude, codex, gemini

    var id: String { rawValue }
    var title: String { AgentCatalog.name(rawValue) }

    init?(agent: String) { self.init(rawValue: agent) }

    var path: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (self == .claude ? ["\(home)/.claude/local"] : [])
        return dirs.map { "\($0)/\(rawValue)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var installed: Bool { path != nil }

    typealias Mode = (id: String?, title: String, hint: String)

    @MainActor
    var modes: [Mode] {
        switch self {
        case .claude: AgentRunner.modes
        case .codex: [
            ("workspace-write", "Proje klasörüne yazar", "Komutlar korumalı alanda çalışır; proje dışına yazamaz"),
            ("read-only", "Salt okunur", "Dosya değiştirmez, yalnızca okur ve anlatır"),
            ("full-access", "Tam erişim ⚠︎", "Korumalı alan ve onay yok; her şeyi çalıştırır"),
        ]
        case .gemini: [
            ("auto_edit", "Düzenlemeleri kabul et", "Dosya düzenlemeleri onaylı; onay isteyen komutlar çalışmaz"),
            ("plan", "Plan", "Değişiklik yapmaz, yalnızca plan çıkarır"),
            ("yolo", "Hepsini onayla ⚠︎", "Komutlar dahil her şeyi sormadan çalıştırır"),
        ]
        }
    }

    /// Terminalsiz çalışmada izin sorulamadığı için Codex ve Gemini işe yarar bir modla başlar.
    @MainActor
    var defaultOptions: AgentRunner.RunOptions {
        switch self {
        case .claude: AgentRunner.RunOptions(mode: nil, model: AgentRunner.model, effort: nil)
        case .codex: AgentRunner.RunOptions(mode: "workspace-write", model: nil, effort: nil)
        case .gemini: AgentRunner.RunOptions(mode: "auto_edit", model: nil, effort: nil)
        }
    }

    @MainActor
    var models: [(id: String?, title: String)] {
        switch self {
        case .claude: AgentRunner.models
        case .codex: [(nil, "Varsayılan")] + CodexModels.shared.list.map { (Optional($0.slug), $0.title) }
        case .gemini: [(nil, "Varsayılan"), ("gemini-2.5-pro", "Gemini 2.5 Pro"), ("gemini-2.5-flash", "Gemini 2.5 Flash")]
        }
    }

    /// Gemini CLI'da efor ayarı yok.
    @MainActor
    var efforts: [String?] {
        switch self {
        case .claude, .codex: AgentRunner.efforts
        case .gemini: []
        }
    }

    func isDangerous(_ mode: String?) -> Bool { ["bypassPermissions", "full-access", "yolo"].contains(mode ?? "") }

    /// Codex'te mod, model ve efor; hem yeni oturumda hem `exec resume`'da geçerli biçimde (resume `-s` almaz).
    func codexArgs(_ o: AgentRunner.RunOptions) -> [String] {
        var a: [String] = []
        switch o.mode {
        case "full-access": a.append("--dangerously-bypass-approvals-and-sandbox")
        case let m?: a += ["-c", "sandbox_mode=\"\(m)\""]
        case nil: break
        }
        if let m = o.model { a += ["-m", m] }
        if let e = o.effort { a += ["-c", "model_reasoning_effort=\"\(e)\""] }
        return a
    }

    func geminiArgs(_ o: AgentRunner.RunOptions) -> [String] {
        var a: [String] = []
        if let m = o.mode { a += ["--approval-mode", m] }
        if let m = o.model { a += ["-m", m] }
        return a
    }

    /// Pepe'nin yürüttüğü oturumu gerçek bir terminalde devralma komutu.
    func resumeArgs(_ sid: String) -> [String] {
        switch self {
        case .claude: ["--resume", sid]
        case .codex: ["resume", sid]
        case .gemini: ["--resume", sid]
        }
    }
}

/// Codex'in bu hesapta kullanılabilen modelleri (`codex debug models`); ilk istekte arka planda okunur.
@MainActor final class CodexModels: ObservableObject {
    static let shared = CodexModels()
    struct Model { let slug: String; let title: String }
    @Published private(set) var list: [Model] = []
    private var loading = false

    func load() {
        guard list.isEmpty, !loading, let codex = RunnableAgent.codex.path else { return }
        loading = true
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: codex)
            p.arguments = ["debug", "models"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let models = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
            let visible = models.filter { $0["visibility"] as? String == "list" }.compactMap { m -> Model? in
                guard let slug = m["slug"] as? String else { return nil }
                return Model(slug: slug, title: m["display_name"] as? String ?? slug)
            }
            await MainActor.run {
                CodexModels.shared.list = visible
                CodexModels.shared.loading = false
            }
        }
    }
}

/// Codex ve Gemini'nin JSON olay akışını Pepe'nin olaylarına çevirir: kart, adımlar ve son cevap hook'larla gelmiş gibi dolar.
@MainActor final class AgentStream {
    let agent: RunnableAgent
    let cwd: String
    let prompt: String
    private(set) var sessionId: String?
    /// Codex oturum kimliğini ilk satırda bildirir; yeni oturumda kart o zaman açılır.
    var onSessionId: ((String) -> Void)?
    private(set) var lastText = ""
    private(set) var error: String?
    private var tools: [String: (name: String, input: [String: Any])] = [:]

    init(agent: RunnableAgent, cwd: String, prompt: String, sessionId: String?) {
        self.agent = agent
        self.cwd = cwd
        self.prompt = prompt
        self.sessionId = sessionId
    }

    /// Kimlik baştan biliniyorsa (Gemini, ya da var olan oturuma yazmak) istek hemen karta düşer.
    func begin() {
        if sessionId != nil { emit("UserPromptSubmit", ["prompt": prompt]) }
    }

    func feed(_ line: Data) {
        guard let e = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = e["type"] as? String else { return }
        switch agent {
        case .codex: codex(type, e)
        case .gemini: gemini(type, e)
        case .claude: break
        }
    }

    /// Süreç bitti: hata yoksa Stop (son cevap) ve Pepe çalıştırmasının sonu.
    func end(status: Int32, stderr: String) {
        if error == nil, status != 0 {
            let tail = stderr.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            error = tail.map { String($0.prefix(300)) } ?? "\(agent.rawValue) \(status) koduyla çıktı."
        }
        if agent == .gemini, error != nil, stderr.contains("GEMINI_API_KEY") || stderr.localizedCaseInsensitiveContains("auth") {
            error = "Gemini CLI'a giriş yapılmamış: terminalde bir kez gemini çalıştırıp giriş yap ya da Ayarlar → Sohbet'e Gemini anahtarı ekle."
        }
        guard let sid = sessionId else { return }
        if let error {
            AppState.shared.store.markFailed(sid, message: error)
        } else {
            emit("Stop", ["last_assistant_message": lastText])
            emit("SessionEnd", [:])
        }
    }

    // MARK: - Codex (`codex exec --json`)

    private func codex(_ type: String, _ e: [String: Any]) {
        switch type {
        case "thread.started":
            guard sessionId == nil, let id = e["thread_id"] as? String else { return }
            sessionId = id
            onSessionId?(id)
            emit("UserPromptSubmit", ["prompt": prompt])
        case "item.started", "item.completed":
            guard let item = e["item"] as? [String: Any] else { return }
            codexItem(item, done: type == "item.completed")
        case "turn.failed":
            error = Self.message((e["error"] as? [String: Any])?["message"] as? String ?? "Codex hata verdi.")
        case "error":
            error = Self.message(e["message"] as? String ?? "Codex hata verdi.")
        default:
            break
        }
    }

    private func codexItem(_ item: [String: Any], done: Bool) {
        let event = done ? "PostToolUse" : "PreToolUse"
        switch item["type"] as? String {
        case "agent_message":
            if done, let t = item["text"] as? String { lastText = t }
        case "command_execution":
            let input: [String: Any] = ["command": item["command"] as? String ?? ""]
            if done {
                let out = item["aggregated_output"] as? String ?? ""
                let failed = (item["exit_code"] as? Int).map { $0 != 0 } ?? false
                emit(event, ["tool_name": "Bash", "tool_input": input, "tool_response": ["stdout": out, "stderr": ""]],
                     failure: failed ? (out.isEmpty ? "Komut başarısız." : out) : nil)
            } else {
                emit(event, ["tool_name": "Bash", "tool_input": input])
            }
        case "file_change":
            for c in item["changes"] as? [[String: Any]] ?? [] {
                let tool = c["kind"] as? String == "add" ? "Write" : "Edit"
                emit(event, ["tool_name": tool, "tool_input": ["file_path": c["path"] as? String ?? ""], "tool_response": [:] as [String: Any]])
            }
        case "mcp_tool_call":
            let name = "mcp__\(item["server"] as? String ?? "mcp")__\(item["tool"] as? String ?? "arac")"
            emit(event, ["tool_name": name, "tool_input": item["arguments"] as? [String: Any] ?? [:]])
        case "web_search":
            emit(event, ["tool_name": "WebSearch", "tool_input": ["query": item["query"] as? String ?? ""]])
        default:
            break
        }
    }

    // MARK: - Gemini CLI (`gemini -o stream-json`)

    private func gemini(_ type: String, _ e: [String: Any]) {
        switch type {
        case "message":
            guard e["role"] as? String == "assistant", let t = e["content"] as? String else { return }
            if e["delta"] as? Bool == true { lastText += t } else { lastText = t }
        case "tool_use":
            let name = e["tool_name"] as? String ?? ""
            let input = e["parameters"] as? [String: Any] ?? [:]
            if let id = e["tool_id"] as? String { tools[id] = (name, input) }
            emit("PreToolUse", ["tool_name": name, "tool_input": input])
        case "tool_result":
            guard let id = e["tool_id"] as? String, let t = tools.removeValue(forKey: id) else { return }
            if e["status"] as? String == "error" {
                let msg = (e["error"] as? [String: Any])?["message"] as? String ?? "Araç hata verdi."
                emit("PostToolUse", ["tool_name": t.name, "tool_input": t.input], failure: msg)
            } else {
                emit("PostToolUse", ["tool_name": t.name, "tool_input": t.input, "tool_response": e["output"] as? String ?? ""])
            }
        case "result":
            if e["status"] as? String == "error" {
                error = Self.message((e["error"] as? [String: Any])?["message"] as? String ?? "Gemini hata verdi.")
            }
        default:
            break
        }
    }

    // MARK: -

    /// Ajanın kendi araç adları AgentNormalizer'la Claude Code biçimine çevrilip hook olayı gibi işlenir.
    private func emit(_ name: String, _ payload: [String: Any], failure: String? = nil) {
        guard let sid = sessionId else { return }
        var p = payload
        p["session_id"] = sid
        p["cwd"] = cwd
        var (event, normalized, id) = AgentNormalizer.normalize(name: name, payload: p, agentArg: agent.rawValue, entry: "")
        if let failure { normalized["tool_response"] = failure }
        _ = AppState.shared.store.handle(HookEvent(name: event, payload: normalized, bundleId: "", term: "", fromSerce: true, agent: id))
    }

    /// API hataları iç içe JSON gelir: {"error":{"message":"…"}}.
    private static func message(_ raw: String) -> String {
        if let d = raw.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let m = (obj["error"] as? [String: Any])?["message"] as? String ?? obj["message"] as? String {
            return String(m.prefix(300))
        }
        return String(raw.prefix(300))
    }
}
