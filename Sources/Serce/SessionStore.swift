import AppKit

enum Mood { case sleep, idle, working, alert, happy, dance }
enum SessionStatus { case idle, working, waiting, done }
enum Decision { case allow, always, deny, terminal }

struct AgentSession: Identifiable {
    /// Ajanın son mesajı (Stop hook'u); Serçe'den yazınca cevap burada görünür.
    var lastReply = ""
    let id: String
    var cwd: String
    var status: SessionStatus = .idle
    var action = "Oturum açıldı"
    var updated = Date()
    var bundleId = ""
    var term = ""
    var tty = ""
    /// Ajan kimliği; görünen ad AgentCatalog.name ile.
    var agent = AgentCatalog.claude
    var prompt = ""
    var steps: [Step] = []
    var finished = false
    var project: String { cwd.isEmpty ? "oturum" : (cwd as NSString).lastPathComponent }
    var agentName: String { AgentCatalog.name(agent) }
}

struct Approval: Identifiable {
    let id = UUID()
    let sessionId: String
    let project: String
    var agent = AgentCatalog.claude
    let tool: String
    let key: String
    let title: String
    let detail: String
    let preview: Step
    let suggestions: [Any]
    let responder: Responder
    /// Serçe'nin kendi istekleri (MCP araçları) için: karar hook'a değil buraya gider.
    var onDecision: ((Decision) -> Void)? = nil
}

/// Bütün oturumların ve bekleyen izinlerin tek kaynağı. Yalnızca ana iş parçacığında yaşar.
@MainActor final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var approvals: [Approval] = []
    /// AskUserQuestion kartları (notch'ta cevaplanır).
    @Published private(set) var questions: [QuestionRequest] = []
    /// Terminale bırakılan soruların anahtarları; aynı soru izin isteği olarak tekrar gelirse kart açılmaz.
    private var questionsSentToTerminal: Set<String> = []
    @Published private(set) var flash: String?
    @Published private(set) var happy = false

    /// Bir izin isteği geldiğinde notch'u açmak için.
    var onAttention: (() -> Void)?

    private var happyTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var pruneTimer: Timer?

    var soundsOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "sesKapali") }
        set { UserDefaults.standard.set(!newValue, forKey: "sesKapali"); objectWillChange.send() }
    }

    init() {
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    var mood: Mood {
        if hasPending { return .alert }
        if happy { return .happy }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        return sessions.isEmpty ? .sleep : .idle
    }

    /// Kullanıcıdan cevap bekleyen bir şey (izin ya da soru) var mı?
    var hasPending: Bool { !approvals.isEmpty || !questions.isEmpty }

    var workingCount: Int { sessions.filter { $0.status == .working }.count }

    // MARK: - Olaylar

    func handle(_ e: HookEvent, responder: Responder? = nil) -> UUID? {
        let p = e.payload
        ProjectMemory.shared.observe(e)
        if e.name == "StatusLine" {
            PlanStore.shared.updateClaude(from: p)
            return nil
        }
        let sid = p["session_id"] as? String ?? "?"
        let tool = p["tool_name"] as? String ?? ""
        let input = p["tool_input"] as? [String: Any] ?? [:]

        let isNew = !sessions.contains { $0.id == sid }
        var s = sessions.first { $0.id == sid } ?? AgentSession(id: sid, cwd: "")
        s.agent = e.agent
        if let cwd = p["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
        if !e.bundleId.isEmpty { s.bundleId = e.bundleId }
        if !e.term.isEmpty { s.term = e.term }
        if e.tty.hasPrefix("/dev/tty") { s.tty = e.tty }
        s.updated = Date()
        if isNew, e.name != "SessionEnd" { RecapStore.shared.recordSession(project: s.project, agent: e.agent) }

        var approvalId: UUID?
        switch e.name {
        case "SessionStart":
            s.status = .idle
            s.action = "Oturum açıldı"
        case "UserPromptSubmit":
            dropApprovals { $0.sessionId == sid }
            dropQuestions { $0.sessionId == sid }
            s.status = .working
            s.action = "Düşünüyor…"
            s.prompt = (p["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            s.steps = []
            s.finished = false
        case "PreToolUse":
            s.status = .working
            s.finished = false
            s.action = ToolText.action(tool, input)
            let key = ToolText.key(tool, input)
            if !s.steps.contains(where: { $0.key == key && $0.status != .done }) {
                s.steps.append(StepBuilder.pre(tool, input))
                if s.steps.count > 40 { s.steps.removeFirst(s.steps.count - 40) }
            }
            RecapStore.shared.recordStep(project: s.project)
        case "PostToolUse":
            // Aynı çağrı için bekleyen kart varsa, kullanıcı terminalden cevaplamıştır.
            let key = ToolText.key(tool, input)
            dropApprovals { $0.sessionId == sid && $0.key == key }
            if let i = s.steps.lastIndex(where: { $0.key == key && $0.status != .done })
                ?? s.steps.lastIndex(where: { $0.tool == tool && $0.status != .done }) {
                StepBuilder.post(&s.steps[i], p["tool_response"])
            } else if !tool.isEmpty {
                // Yalnızca "sonra" olayı gönderen ajanlar (Cursor, OpenCode) için adımı burada kur.
                var step = StepBuilder.pre(tool, input)
                StepBuilder.post(&step, p["tool_response"])
                s.steps.append(step)
                if s.steps.count > 40 { s.steps.removeFirst(s.steps.count - 40) }
                s.action = ToolText.action(tool, input)
                RecapStore.shared.recordStep(project: s.project)
            }
            if !approvals.contains(where: { $0.sessionId == sid }) { s.status = .working }
        case "PermissionRequest":
            guard let responder else { break }
            if tool == "AskUserQuestion" {
                // Eski Claude Code sürümleri soruyu izin isteği olarak gönderir; cevap aynı kartla verilir.
                let key = ToolText.key(tool, input)
                if questionsSentToTerminal.contains(key) || questions.contains(where: { $0.key == key }) {
                    responder.respond("")
                } else if let id = openQuestion(&s, input: input, key: key, format: .permissionRequest, responder: responder) {
                    approvalId = id
                } else {
                    responder.respond("")
                }
                break
            }
            let a = Approval(sessionId: sid, project: s.project, agent: e.agent, tool: tool,
                             key: ToolText.key(tool, input),
                             title: ToolText.permissionTitle(tool),
                             detail: ToolText.detail(tool, input),
                             preview: StepBuilder.preview(tool, input),
                             suggestions: p["permission_suggestions"] as? [Any] ?? [],
                             responder: responder)
            approvals.append(a)
            approvalId = a.id
            s.status = .waiting
            s.action = "İzin bekliyor · " + ToolText.action(tool, input)
            if let i = s.steps.lastIndex(where: { $0.key == a.key }) { s.steps[i].status = .waiting }
            else { s.steps.append(a.preview) }
            play(.approval)
            onAttention?()
            // Claude Code hook'u ~120 sn bekler; ondan önce terminale bırak.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(110))
                self?.dropApprovals { $0.id == a.id }
            }
        case "Ask":
            // AskUserQuestion için ayrılmış PreToolUse hook'u (matcher: AskUserQuestion).
            guard let responder else { break }
            let key = ToolText.key(tool, input)
            if let id = openQuestion(&s, input: input, key: key, format: .preToolUse, responder: responder) {
                approvalId = id
            } else {
                responder.respond("")
            }
        case "Notification":
            let msg = p["message"] as? String ?? ""
            if approvals.contains(where: { $0.sessionId == sid }) { break }
            if msg.localizedCaseInsensitiveContains("waiting for your input") {
                s.status = .idle
                s.action = "Seni bekliyor"
            } else if msg.localizedCaseInsensitiveContains("permission") {
                s.status = .waiting
                s.action = "Terminalde izin bekliyor"
            } else if !msg.isEmpty {
                s.action = msg
            }
        case "Stop":
            if let m = p["last_assistant_message"] as? String, !m.isEmpty { s.lastReply = String(m.suffix(4000)) }
            dropApprovals { $0.sessionId == sid }
            dropQuestions { $0.sessionId == sid }
            s.status = .done
            s.action = "Bitti"
            s.finished = true
            for i in s.steps.indices where s.steps[i].status == .running || s.steps[i].status == .waiting {
                s.steps[i].status = .done
            }
            celebrate(s.project)
        case "SessionEnd":
            dropApprovals { $0.sessionId == sid }
            dropQuestions { $0.sessionId == sid }
            sessions.removeAll { $0.id == sid }
            return nil
        default:
            return nil
        }
        upsert(s)
        return approvalId
    }

    func decide(_ a: Approval, _ d: Decision) {
        if let done = a.onDecision {
            done(d)
            approvals.removeAll { $0.id == a.id }
            return
        }
        let body = AgentCatalog.permissionOutput(agent: a.agent, decision: d, suggestions: a.suggestions)
        RecapStore.shared.recordDecision(d)
        a.responder.respond(body)
        approvals.removeAll { $0.id == a.id }
        if let i = sessions.firstIndex(where: { $0.id == a.sessionId }) {
            sessions[i].status = d == .terminal ? .waiting : .working
            sessions[i].action = d == .terminal ? "Terminalde izin bekliyor" : (d == .deny ? "Reddedildi" : "İzin verildi")
            if let j = sessions[i].steps.lastIndex(where: { $0.key == a.key }) {
                sessions[i].steps[j].status = d == .deny ? .failed : (d == .terminal ? .waiting : .running)
            }
        }
    }

    /// Hook süreci kapandı ya da süre doldu: kartı kaldır, Claude Code terminalde sorar.
    func dropApproval(_ id: UUID) {
        dropApprovals { $0.id == id }
        dropQuestions { $0.id == id }
    }

    // MARK: - Sorular

    private func openQuestion(_ s: inout AgentSession, input: [String: Any], key: String,
                              format: QuestionRequest.Format, responder: Responder) -> UUID? {
        guard let items = QuestionItem.parse(input) else { return nil }
        if let old = questions.first(where: { $0.key == key }) { old.responder.respond("") }
        questions.removeAll { $0.key == key }
        let q = QuestionRequest(sessionId: s.id, project: s.project, agent: s.agent, key: key,
                                items: items, rawQuestions: input["questions"] as? [Any] ?? [],
                                format: format, responder: responder)
        questions.append(q)
        s.status = .waiting
        s.action = "Sana soru soruyor"
        play(.chirp)
        onAttention?()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(format == .preToolUse ? 120 : 110))
            self?.dropQuestions { $0.id == q.id }
        }
        return q.id
    }

    /// Seçimleri ajana gönderir. selections[i] = i. sorunun seçilen etiketleri.
    func answer(_ q: QuestionRequest, selections: [[String]]) {
        q.responder.respond(q.output(selections: selections))
        RecapStore.shared.recordAnswer()
        questions.removeAll { $0.id == q.id }
        if let i = sessions.firstIndex(where: { $0.id == q.sessionId }) {
            sessions[i].status = .working
            sessions[i].action = "Cevap verildi"
        }
    }

    /// Soruyu terminale bırakır: ajan kendi arayüzünde sorar.
    func questionToTerminal(_ q: QuestionRequest) {
        questionsSentToTerminal.insert(q.key)
        q.responder.respond("")
        questions.removeAll { $0.id == q.id }
        if let i = sessions.firstIndex(where: { $0.id == q.sessionId }) {
            sessions[i].action = "Soru terminalde"
        }
    }

    private func dropQuestions(where match: (QuestionRequest) -> Bool) {
        for q in questions where match(q) { q.responder.respond("") }
        questions.removeAll(where: match)
    }

    private func dropApprovals(where match: (Approval) -> Bool) {
        for a in approvals where match(a) {
            a.responder.respond("")
            a.onDecision?(.deny)
        }
        approvals.removeAll(where: match)
    }

    // MARK: - Yardımcılar

    /// Kartlar yerinde güncellenir; tıklamak üzereyken altından kaymasın diye yalnızca yeni oturum en üste girer.
    private func upsert(_ s: AgentSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.insert(s, at: 0) }
    }

    private func celebrate(_ project: String) {
        happy = true
        happyTask?.cancel()
        happyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled { self?.happy = false }
        }
        showFlash("\(project) bitti")
        play(.done)
    }

    private func showFlash(_ text: String) {
        flash = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.flash = nil }
        }
    }

    /// Serçe'nin kendisi (sohbet/sesli asistan) bir MCP aracı çalıştırmadan önce notch'ta onay ister.
    /// 2 dakika içinde cevap gelmezse reddedilmiş sayılır.
    func requestLocalApproval(project: String, tool: String, title: String, input: [String: Any], allowAlways: Bool) async -> Decision {
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let key = UUID().uuidString
        let preview = Step(tool: "MCP", key: key, title: tool, subtitle: "", path: nil, status: .waiting,
                           content: .text(json.isEmpty ? "(parametre yok)" : json))
        return await withCheckedContinuation { (c: CheckedContinuation<Decision, Never>) in
            let once = Responder { _ in }
            var resumed = false
            var a = Approval(sessionId: "serce-yerel", project: project, tool: tool, key: key, title: title,
                             detail: json, preview: preview, suggestions: allowAlways ? [["type": "serce"]] : [], responder: once)
            a.onDecision = { d in
                guard !resumed else { return }
                resumed = true
                c.resume(returning: d)
            }
            approvals.append(a)
            play(.approval)
            onAttention?()
            let id = a.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                self?.dropApprovals { $0.id == id }
            }
        }
    }

    private func play(_ cue: SoundEngine.Cue) {
        SoundEngine.shared.play(cue)
    }

    private func prune() {
        let limit = Date().addingTimeInterval(-20 * 60)
        let waiting = Set(approvals.map(\.sessionId))
        sessions.removeAll { $0.updated < limit && $0.status != .waiting && !waiting.contains($0.id) }
    }

    /// Oturumun tam penceresine gider: Terminal/iTerm'de TTY'si eşleşen sekme, editörlerde projenin penceresi.
    func openTerminal(for s: AgentSession) {
        let byTerm = ["Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
                      "ghostty": "com.mitchellh.ghostty", "vscode": "com.microsoft.VSCode",
                      "WarpTerminal": "dev.warp.Warp-Stable", "kitty": "net.kovidgoyal.kitty"]
        let ids = [s.bundleId, byTerm[s.term] ?? ""].filter { !$0.isEmpty }
        guard let id = ids.first(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }

        let editors: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                                    "com.exafunction.windsurf", "dev.zed.Zed"]
        if editors.contains(id), !s.cwd.isEmpty {
            NSWorkspace.shared.open([URL(fileURLWithPath: s.cwd)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if !s.tty.isEmpty, let script = Self.focusScript(bundleId: id, tty: s.tty) {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil { return }
        }
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }

    private static func focusScript(bundleId: String, tty: String) -> String? {
        switch bundleId {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return
                  end if
                end repeat
              end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                      activate
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        default:
            return nil
        }
    }
}
