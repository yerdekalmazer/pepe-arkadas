import AppKit

enum Mood { case sleep, idle, working, alert, happy }
enum SessionStatus { case idle, working, waiting, done }
enum Decision { case allow, always, deny, terminal }

struct AgentSession: Identifiable {
    let id: String
    var cwd: String
    var status: SessionStatus = .idle
    var action = "Oturum açıldı"
    var updated = Date()
    var bundleId = ""
    var term = ""
    var tty = ""
    var prompt = ""
    var steps: [Step] = []
    var finished = false
    var project: String { cwd.isEmpty ? "oturum" : (cwd as NSString).lastPathComponent }
}

struct Approval: Identifiable {
    let id = UUID()
    let sessionId: String
    let project: String
    let tool: String
    let key: String
    let title: String
    let detail: String
    let preview: Step
    let suggestions: [Any]
    let responder: Responder
}

/// Bütün oturumların ve bekleyen izinlerin tek kaynağı. Yalnızca ana iş parçacığında yaşar.
@MainActor final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var approvals: [Approval] = []
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
        if !approvals.isEmpty { return .alert }
        if happy { return .happy }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        return sessions.isEmpty ? .sleep : .idle
    }

    var workingCount: Int { sessions.filter { $0.status == .working }.count }

    // MARK: - Olaylar

    func handle(_ e: HookEvent, responder: Responder? = nil) -> UUID? {
        let p = e.payload
        let sid = p["session_id"] as? String ?? "?"
        let tool = p["tool_name"] as? String ?? ""
        let input = p["tool_input"] as? [String: Any] ?? [:]

        var s = sessions.first { $0.id == sid } ?? AgentSession(id: sid, cwd: "")
        if let cwd = p["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
        if !e.bundleId.isEmpty { s.bundleId = e.bundleId }
        if !e.term.isEmpty { s.term = e.term }
        if e.tty.hasPrefix("/dev/tty") { s.tty = e.tty }
        s.updated = Date()

        var approvalId: UUID?
        switch e.name {
        case "SessionStart":
            s.status = .idle
            s.action = "Oturum açıldı"
        case "UserPromptSubmit":
            dropApprovals { $0.sessionId == sid }
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
        case "PostToolUse":
            // Aynı çağrı için bekleyen kart varsa, kullanıcı terminalden cevaplamıştır.
            let key = ToolText.key(tool, input)
            dropApprovals { $0.sessionId == sid && $0.key == key }
            if let i = s.steps.lastIndex(where: { $0.key == key && $0.status != .done })
                ?? s.steps.lastIndex(where: { $0.tool == tool && $0.status != .done }) {
                StepBuilder.post(&s.steps[i], p["tool_response"])
            }
            if !approvals.contains(where: { $0.sessionId == sid }) { s.status = .working }
        case "PermissionRequest":
            guard let responder else { break }
            if tool == "AskUserQuestion" {
                // Sorular terminalde cevaplanır; Serçe yalnızca haber verir.
                responder.respond("")
                s.status = .waiting
                s.action = "Sana soru soruyor — terminale bak"
                showFlash("\(s.project) bir soru soruyor")
                play("Pop")
                break
            }
            let a = Approval(sessionId: sid, project: s.project, tool: tool,
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
            play("Pop")
            onAttention?()
            // Claude Code hook'u ~120 sn bekler; ondan önce terminale bırak.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(110))
                self?.dropApprovals { $0.id == a.id }
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
            dropApprovals { $0.sessionId == sid }
            s.status = .done
            s.action = "Bitti"
            s.finished = true
            for i in s.steps.indices where s.steps[i].status == .running || s.steps[i].status == .waiting {
                s.steps[i].status = .done
            }
            celebrate(s.project)
        case "SessionEnd":
            dropApprovals { $0.sessionId == sid }
            sessions.removeAll { $0.id == sid }
            return nil
        default:
            return nil
        }
        upsert(s)
        return approvalId
    }

    func decide(_ a: Approval, _ d: Decision) {
        var decision: [String: Any]
        switch d {
        case .allow: decision = ["behavior": "allow"]
        case .always: decision = ["behavior": "allow", "updatedPermissions": a.suggestions]
        case .deny: decision = ["behavior": "deny", "message": "Serçe'den reddedildi"]
        case .terminal: decision = [:]
        }
        var body = ""
        if !decision.isEmpty {
            let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
            body = String(data: (try? JSONSerialization.data(withJSONObject: out)) ?? Data(), encoding: .utf8) ?? ""
        }
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
    func dropApproval(_ id: UUID) { dropApprovals { $0.id == id } }

    private func dropApprovals(where match: (Approval) -> Bool) {
        for a in approvals where match(a) { a.responder.respond("") }
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
        play("Glass")
    }

    private func showFlash(_ text: String) {
        flash = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.flash = nil }
        }
    }

    private func play(_ name: String) {
        guard soundsOn else { return }
        NSSound(named: NSSound.Name(name))?.play()
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
