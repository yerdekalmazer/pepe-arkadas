import SwiftUI

@MainActor final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var expandedHeight: CGFloat = 180
    /// Notch altındaki sesli asistan baloncuğunun yüksekliği (0 = görünmüyor); tıklama alanı için.
    @Published var captionHeight: CGFloat = 0
    @Published var hooksInstalled = false
    /// Detayı açılan oturum; nil ise ana sayfa.
    @Published var selectedSession: String?
    /// Kullanıcının tıkladığı adım; nil ise görüntüleyici son adımı izler.
    @Published var pinnedStep: UUID?
    /// "Yeni oturum" ekranı açıkken önceden seçili proje klasörü ("" = seçilmedi).
    @Published var newSessionCwd: String?
    /// Ana sayfada tüm oturumlar mı (en çok 8) yoksa ilk 3 mü gösterilsin.
    @Published var showAllSessions = false
    let wing: CGFloat = 40
    let ear: CGFloat = 7
    let expandedWidth: CGFloat = 660

    var collapsedSize: CGSize { CGSize(width: notchWidth + 2 * wing + 2 * ear, height: notchHeight) }
}

struct NotchActions {
    var decide: (Approval, Decision) -> Void
    var openTerminal: (AgentSession) -> Void
    var installHooks: () -> Void
    var showMenu: () -> Void
    var answer: (QuestionRequest, [[String]]) -> Void = { _, _ in }
    var questionToTerminal: (QuestionRequest) -> Void = { _ in }
}

/// Ekranın üst kenarına yapışan siyah ada: iki yanda içe kıvrılan "kulaklar", altta yuvarlak köşeler.
struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, e = ear, b = min(radius, h / 2)
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: e, y: e), control: CGPoint(x: e, y: 0))
        p.addLine(to: CGPoint(x: e, y: h - b))
        p.addQuadCurve(to: CGPoint(x: e + b, y: h), control: CGPoint(x: e, y: h))
        p.addLine(to: CGPoint(x: w - e - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - e, y: h - b), control: CGPoint(x: w - e, y: h))
        p.addLine(to: CGPoint(x: w - e, y: e))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - e, y: 0))
        p.closeSubpath()
        return p
    }
}

private struct CaptionKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct NotchRoot: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchModel
    let actions: NotchActions

    var body: some View {
        let size = model.expanded
            ? CGSize(width: model.expandedWidth, height: model.expandedHeight)
            : model.collapsedSize
        ZStack(alignment: .top) {
            if model.expanded {
                ExpandedView(app: app, store: store, pills: app.pills, model: model, actions: actions)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                CollapsedView(store: store, model: model)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(NotchShape(ear: model.ear, radius: model.expanded ? 26 : 12).fill(.black))
        .clipShape(NotchShape(ear: model.ear, radius: model.expanded ? 26 : 12))
        .onPreferenceChange(HeightKey.self) { h in if h > 0 { model.expandedHeight = h } }
        .overlay(alignment: .top) {
            // Sesli asistan baloncuğu adanın hemen altında durur; ada açıkken gizlenir.
            if !model.expanded {
                VoiceCaption(engine: .shared)
                    .background(GeometryReader { Color.clear.preference(key: CaptionKey.self, value: $0.size.height) })
                    .offset(y: size.height + 6)
            }
        }
        .onPreferenceChange(CaptionKey.self) { model.captionHeight = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.expanded)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.expandedHeight)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Kapalı hal

struct CollapsedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchModel
    /// Müzik çalarken sağ kanatta ekolayzır göstermek için.
    @ObservedObject var app: AppState = .shared
    /// Sesli asistan dinlerken/konuşurken kuşun hali değişsin diye.
    @ObservedObject var voice: VoiceEngine = .shared

    var body: some View {
        HStack(spacing: 0) {
            Bird(mood: AppState.shared.mood, size: model.notchHeight * 0.78, interactive: true)
                .birdDragSource()
                .frame(width: model.wing)
            Color.clear.frame(width: model.notchWidth)
            indicator.frame(width: model.wing)
        }
        .padding(.horizontal, model.ear)
        .frame(height: model.notchHeight)
    }

    @ViewBuilder private var indicator: some View {
        if store.hasPending {
            Text("!")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.amber)
                .phaseAnimator([1.0, 1.35]) { v, s in v.scaleEffect(s) } animation: { _ in .easeInOut(duration: 0.4) }
        } else if store.flash != nil {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.green)
        } else if store.workingCount > 0 {
            WorkingDots(count: store.workingCount)
        } else if app.musicPlaying {
            // Müzik pill'i çalıyor: küçük ekolayzır.
            Equalizer(color: Palette.green, bars: 4, height: 11)
        }
    }
}

struct WorkingDots: View {
    var count: Int
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Palette.blue)
                        .frame(width: 4, height: 4)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
                if count > 1 {
                    Text("\(count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }
}

// MARK: - Açık hal

struct ExpandedView: View {
    @ObservedObject var reminders = Reminders.shared
    @ObservedObject var briefing = Briefing.shared
    @ObservedObject var app: AppState
    @ObservedObject var store: SessionStore
    @ObservedObject var pills: PillRegistry
    @ObservedObject var model: NotchModel
    let actions: NotchActions
    @ObservedObject var plan = PlanStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar.frame(height: model.notchHeight)
            panel
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.panel))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.06)))
        }
        .padding(.horizontal, model.ear + 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var panel: some View {
        if let a = store.approvals.first {
            ApprovalView(approval: a, more: store.approvals.count - 1 + store.questions.count, actions: actions)
        } else if let q = store.questions.first {
            QuestionView(request: q, more: store.questions.count - 1,
                         answer: { actions.answer(q, $0) }, toTerminal: { actions.questionToTerminal(q) })
                .id(q.id)
        } else if plan.showDetail, plan.isVisible {
            PlanDetailCard(plan: plan)
        } else {
            switch app.tab {
            case .chat: ChatTabView(app: app)
            case .drop: DropTabView(app: app)
            case .home: home
            }
        }
    }

    @ViewBuilder private var home: some View {
        if model.selectedSession == nil, model.newSessionCwd == nil, !Reminders.shared.due.isEmpty || Briefing.shared.visible {
            VStack(spacing: 8) {
                ReminderBanner(reminders: .shared)
                BriefingCard(briefing: .shared)
                homeContent
            }
        } else {
            homeContent
        }
    }

    @ViewBuilder private var homeContent: some View {
        if let cwd = model.newSessionCwd {
            NewSessionView(model: model, store: store, presetCwd: cwd)
        } else if let id = model.selectedSession, let s = store.sessions.first(where: { $0.id == id }) {
            SessionDetail(session: s, model: model, open: { actions.openTerminal(s) })
        } else if pills.active.isEmpty {
            leftCard
        } else {
            HStack(alignment: .top, spacing: 10) {
                leftCard.frame(maxWidth: .infinity, alignment: .topLeading)
                PillGrid(app: app, registry: pills).frame(width: 230)
            }
        }
    }

    /// Seçili pill'in kartı; seçim yoksa ajan oturumları.
    @ViewBuilder private var leftCard: some View {
        if let id = app.selectedPill, let p = pills.provider(id) {
            p.card()
        } else if !model.hooksInstalled {
            ConnectCard(install: actions.installHooks)
        } else if store.sessions.isEmpty {
            HStack(spacing: 14) {
                Bird(mood: .sleep, size: 44, interactive: true)
                    .birdDragSource()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ortalık sakin").font(.system(size: 13, weight: .semibold))
                    Text("Bir terminalde claude'u başlat; Serçe her adımı burada gösterir.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    RecapLine(store: .shared)
                }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(store.sessions.prefix(model.showAllSessions ? 8 : 3)) { s in
                    SessionCard(session: s) {
                        model.pinnedStep = nil
                        model.selectedSession = s.id
                    }
                }
                HStack {
                    if store.sessions.count > 3 {
                        Button(model.showAllSessions ? "Daha az göster" : "+\(store.sessions.count - 3) oturum daha") {
                            model.showAllSessions.toggle()
                        }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { model.newSessionCwd = "" } label: {
                        Label("Yeni oturum", systemImage: "plus").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(Pill(kind: .quiet))
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            TabIcon(symbol: "house.fill", selected: app.tab == .home) {
                app.tab = .home
                model.selectedSession = nil
                model.pinnedStep = nil
            }
            TabIcon(symbol: "bubble.left.fill", selected: app.tab == .chat) { app.tab = .chat }
            TabIcon(symbol: "plus", selected: app.tab == .drop) { app.tab = .drop }
            Spacer(minLength: model.notchWidth)
            PlanPill(plan: plan)
            TabIcon(symbol: "gearshape", selected: false, action: actions.showMenu)
            TabIcon(symbol: store.soundsOn ? "speaker.wave.2" : "speaker.slash", selected: false) {
                store.soundsOn.toggle()
            }
        }
        .padding(.horizontal, 6)
    }
}

struct TabIcon: View {
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? .white : .white.opacity(hover ? 0.85 : 0.55))
                .frame(width: 34, height: 24)
                .background(Capsule().fill(.white.opacity(selected ? 0.14 : (hover ? 0.06 : 0))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Ana sayfa kartı

struct SessionCard: View {
    let session: AgentSession
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BirdTile(session: session, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor(session)).frame(width: 6, height: 6)
                    Text(session.project).font(.system(size: 12, weight: .bold))
                    if session.ended {
                        Text("kapalı").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.08)))
                    }
                    if let w = session.worktree { WorktreeChip(name: w) }
                    Text(session.agentName).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if !session.steps.isEmpty {
                        Text(counter).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                current
                preview
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.07 : 0.035)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
    }

    private var counter: String {
        let done = session.steps.filter { $0.status == .done }.count
        return "\(done)/\(session.steps.count)"
    }

    @ViewBuilder private var current: some View {
        if session.finished {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                Text("Bitti").fontWeight(.semibold).foregroundStyle(Palette.green)
                Text(session.prompt.isEmpty ? "" : session.prompt).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.system(size: 11))
        } else if let step = session.steps.last {
            HStack(spacing: 5) {
                Image(systemName: step.icon).foregroundStyle(.secondary).frame(width: 12)
                Text(step.title).fontWeight(.semibold)
                Text(step.path.map { relativePath($0, cwd: session.cwd) } ?? step.subtitle)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11))
        } else {
            Text(session.action).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Son komutun terminal çıktısı; yoksa son kod adımından birkaç satır.
    @ViewBuilder private var preview: some View {
        if let bash = session.steps.last(where: { $0.tool == "Bash" }), case .terminal(let cmd, let out, _) = bash.content {
            VStack(alignment: .leading, spacing: 1) {
                Text("$ " + cmd.split(separator: "\n").first.map(String.init)!).foregroundStyle(.white.opacity(0.85))
                ForEach(Array(out.split(separator: "\n", omittingEmptySubsequences: true).suffix(3).enumerated()), id: \.offset) { _, line in
                    Text(Terminal.colored(String(line)))
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.5)))
        } else if !session.prompt.isEmpty, !session.finished {
            Text("“\(session.prompt)”").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
        }
    }
}

// MARK: - Oturum detayı

struct SessionDetail: View {
    let session: AgentSession
    @ObservedObject var model: NotchModel
    let open: () -> Void
    @ObservedObject private var runner = AgentRunner.shared
    @State private var draft = ""
    @State private var sendError: String?
    @State private var confirmClose = false
    @Environment(\.snapshotMode) private var snapshot

    /// Adım listesinde "Yanıt" satırının sabit kimliği.
    static let replyId = UUID()

    var body: some View {
        let visible = Array(session.steps.suffix(6))
        let hasReply = !session.lastReply.isEmpty
        // Oturum bittiyse ve kullanıcı bir adım seçmediyse ajanın cevabı gösterilir.
        let showReply = hasReply && (model.pinnedStep == Self.replyId || (model.pinnedStep == nil && session.status != .working))
        let selected = visible.first { $0.id == model.pinnedStep } ?? visible.last
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                BirdTile(session: session, size: 64)
                Text(session.project).font(.system(size: 14, weight: .bold)).lineLimit(1).padding(.top, 10)
                Text(session.agentName).font(.system(size: 11)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(visible) { step in
                        StepRow(step: step, selected: !showReply && step.id == selected?.id) {
                            model.pinnedStep = step.id
                        }
                    }
                    if hasReply {
                        HStack(spacing: 7) {
                            Image(systemName: session.finished ? "checkmark.circle.fill" : "text.bubble.fill")
                                .foregroundStyle(session.finished ? Palette.green : .secondary).frame(width: 14)
                            Text("Yanıt").font(.system(size: 12, weight: showReply ? .semibold : .regular))
                                .foregroundStyle(showReply ? .white : .white.opacity(0.7))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.pinnedStep = Self.replyId }
                    } else if visible.isEmpty {
                        Text(session.action).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 14)
                Spacer(minLength: 10)
                if let w = session.worktree { WorktreeChip(name: w).padding(.bottom, 6) }
                Button { model.newSessionCwd = ProjectMemory.projectRoot(session.cwd) } label: {
                    Label("Yeni oturum", systemImage: "plus").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(Pill(kind: .quiet))
                .padding(.bottom, 4)
                let headless = session.launchedBySerce || session.ended || (session.tty.isEmpty && session.bundleId.isEmpty)
                Button {
                    // Terminali olmayan (Serçe'nin başlattığı ya da kapanmış) oturum: gerçek bir terminalde devral.
                    if headless {
                        sendError = AgentRunner.shared.openInTerminal(session)
                    } else {
                        open()
                    }
                } label: {
                    Label(headless ? "Terminalde aç" : "Terminale git", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(Pill(kind: .quiet))
                .padding(.bottom, 4)
                if session.ended {
                    Button { AppState.shared.store.forget(session.id); model.selectedSession = nil } label: {
                        Label("Listeden kaldır", systemImage: "xmark.circle").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(Pill(kind: .quiet))
                } else if !headless {
                    closeButton
                }
            }
            .frame(width: 140, alignment: .leading)

            VStack(spacing: 8) {
                if showReply {
                    ReplyView(text: session.lastReply)
                } else {
                    Viewer(step: selected, cwd: session.cwd, prompt: session.prompt)
                }
                composer
            }
        }
        .frame(height: 320)
    }

    /// Terminal açık olmasa da bu oturuma yaz: `claude -p --resume` arka planda çalışır.
    @ViewBuilder private var composer: some View {
        let busy = runner.isRunning(session.id)
        let canSend = session.agent == AgentCatalog.claude && session.status != .working && !busy
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if snapshot {
                    // ImageRenderer metin kutusunu çizemez.
                    Text(placeholder(busy: busy)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                } else {
                    TextField(placeholder(busy: busy), text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .disabled(!canSend)
                        .onSubmit(send)
                }
                if busy {
                    Button { runner.stop(session.id) } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain).help("Durdur")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                            .foregroundStyle(canSend && !draft.isEmpty ? .white : .white.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend || draft.isEmpty)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(0.07)))
            if let err = sendError ?? runner.lastError[session.id] {
                Text(err).font(.system(size: 10)).foregroundStyle(Palette.red).lineLimit(2)
            }
        }
    }

    /// İki adımlı: ilk tık "Emin misin?", ikinci tık ajan sürecini kapatır (terminal sekmesi açık kalır).
    @ViewBuilder private var closeButton: some View {
        Button {
            if confirmClose {
                sendError = AppState.shared.store.closeSession(session)
                confirmClose = false
            } else {
                confirmClose = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirmClose = false }
            }
        } label: {
            Label(confirmClose ? "Emin misin?" : "Oturumu kapat", systemImage: "power")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(confirmClose ? Palette.red : .white.opacity(0.9))
        }
        .buttonStyle(Pill(kind: .quiet))
        .help("Terminaldeki ajan oturumunu sonlandırır; terminal sekmesi açık kalır")
    }

    private func placeholder(busy: Bool) -> String {
        if busy { return "Serçe bu oturumu yürütüyor…" }
        if session.ended, session.agent == AgentCatalog.claude { return "Terminal kapalı — yazarsan Serçe arka planda sürdürür" }
        if session.agent != AgentCatalog.claude { return "Şimdilik yalnızca Claude Code oturumlarına yazılabiliyor" }
        if session.status == .working { return "Oturum çalışıyor; bitince yazabilirsin" }
        return "\(session.project) oturumuna yaz — terminal kapalı olsa da devam eder"
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sendError = AgentRunner.shared.send(text, to: session)
        if sendError == nil {
            draft = ""
            model.pinnedStep = nil
        }
    }
}

/// Ajanın son cevabı: markdown, okunur yazı tipiyle.
struct ReplyView: View {
    let text: String
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let content = Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.88))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        Group {
            if snapshot { content.frame(maxHeight: .infinity, alignment: .top).clipped() } else { ScrollView { content } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.editor))
    }
}

struct StepRow: View {
    let step: Step
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            StatusIcon(status: step.status).frame(width: 14)
            Text(step.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : .white.opacity(step.status == .done ? 0.6 : 0.85))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }
}

struct StatusIcon: View {
    let status: StepStatus
    var body: some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green).font(.system(size: 12))
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.red).font(.system(size: 12))
        case .waiting: Image(systemName: "hand.raised.circle.fill").foregroundStyle(Palette.amber).font(.system(size: 12))
        case .running: Spinner().frame(width: 11, height: 11)
        }
    }
}

struct Spinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.radians(tl.date.timeIntervalSinceReferenceDate * 6))
        }
    }
}

// MARK: - Görüntüleyici: kod, diff, terminal

struct Viewer: View {
    let step: Step?
    let cwd: String
    let prompt: String
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(0.03))
            Divider().overlay(.white.opacity(0.05))
            if snapshot {
                // ImageRenderer kaydırma alanını çizmez; anlık görüntüde içerik düz basılır.
                content.padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical]) {
                        content.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { scroll(proxy) }
                    .onChange(of: step?.id) { scroll(proxy) }
                    .onChange(of: outputLength) { scroll(proxy) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.editor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var outputLength: Int {
        if case .terminal(_, let out, _) = step?.content { return out.count }
        return 0
    }

    /// Diff'te ilk değişen satıra, terminalde en alta kaydır.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let step else { return }
        switch step.content {
        case .code(let lines):
            if let i = lines.firstIndex(where: { $0.kind != .context }), lines.contains(where: { $0.kind == .context }) {
                proxy.scrollTo(max(0, i - 3), anchor: .top)
            }
        case .terminal:
            proxy.scrollTo("son", anchor: .bottom)
        case .text:
            break
        }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 7) {
            if let step, let path = step.path {
                let name = (path as NSString).lastPathComponent
                FileBadge(ext: (name as NSString).pathExtension)
                Text(name).font(.system(size: 11, weight: .medium, design: .monospaced))
                if step.tool != "Read" { Circle().fill(Palette.amber).frame(width: 5, height: 5) }
                Spacer()
                Text(relative(path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            } else if let step {
                Image(systemName: step.icon).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(step.tool == "Bash" ? "Terminal" : step.title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(StepBuilder.short(cwd)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            } else {
                Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("İstek").font(.system(size: 11, weight: .medium))
                Spacer()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let step {
            switch step.content {
            case .code(let lines):
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        CodeRow(line: line).id(i)
                    }
                }
            case .terminal(let cmd, let out, let failed):
                VStack(alignment: .leading, spacing: 2) {
                    (Text("$ ").foregroundColor(Palette.green) + Text(cmd).foregroundColor(.white))
                    if out.isEmpty, step.status == .running {
                        Spinner().frame(width: 9, height: 9).padding(.top, 3)
                    }
                    ForEach(Array(out.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(failed ? AttributedString(line) : Terminal.colored(line))
                            .foregroundStyle(failed ? Palette.red : .white.opacity(0.75))
                    }
                    Color.clear.frame(height: 1).id("son")
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
            case .text(let text):
                Text(text.isEmpty ? step.subtitle : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
            }
        } else {
            Text(prompt.isEmpty ? "Henüz adım yok." : prompt)
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 12)
        }
    }

    private func relative(_ path: String) -> String { relativePath(path, cwd: cwd) }
}

struct CodeRow: View {
    let line: CodeLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.number.map(String.init) ?? "")
                .foregroundStyle(numberColor)
                .frame(width: 34, alignment: .trailing)
            Text(sign).foregroundStyle(signColor).frame(width: 20)
            Text(Syntax.highlight(line.text))
                .strikethrough(line.kind == .removed, color: Palette.red.opacity(0.6))
                .opacity(line.kind == .removed ? 0.6 : 1)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 2)
        .background(background)
        .overlay(alignment: .leading) {
            if line.kind != .context { Rectangle().fill(signColor).frame(width: 2) }
        }
    }

    private var sign: String { line.kind == .added ? "+" : (line.kind == .removed ? "-" : "") }
    private var signColor: Color { line.kind == .added ? Palette.green : Palette.red }
    private var numberColor: Color {
        switch line.kind {
        case .added: Palette.green.opacity(0.8)
        case .removed: Palette.red.opacity(0.8)
        case .context: .white.opacity(0.28)
        }
    }
    private var background: Color {
        switch line.kind {
        case .added: Palette.green.opacity(0.11)
        case .removed: Palette.red.opacity(0.13)
        case .context: .clear
        }
    }
}

struct FileBadge: View {
    let ext: String
    var body: some View {
        let (label, color) = Self.style(ext.lowercased())
        Text(label)
            .font(.system(size: 7.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 18, height: 13)
            .background(RoundedRectangle(cornerRadius: 3).fill(color))
    }

    static func style(_ e: String) -> (String, Color) {
        switch e {
        case "ts", "tsx": ("TS", Color(red: 0.19, green: 0.47, blue: 0.78))
        case "js", "jsx", "mjs", "cjs": ("JS", Color(red: 0.80, green: 0.66, blue: 0.10))
        case "swift": ("SW", Color(red: 0.94, green: 0.32, blue: 0.22))
        case "py": ("PY", Color(red: 0.22, green: 0.45, blue: 0.68))
        case "json": ("{}", Color(red: 0.45, green: 0.45, blue: 0.50))
        case "md": ("MD", Color(red: 0.35, green: 0.40, blue: 0.48))
        case "html": ("<>", Color(red: 0.89, green: 0.30, blue: 0.15))
        case "css": ("CS", Color(red: 0.40, green: 0.30, blue: 0.75))
        case "go": ("GO", Color(red: 0.0, green: 0.62, blue: 0.75))
        case "rs": ("RS", Color(red: 0.70, green: 0.38, blue: 0.25))
        case "sh", "zsh": ("SH", Color(red: 0.30, green: 0.55, blue: 0.30))
        default: (e.isEmpty ? "··" : String(e.prefix(2)).uppercased(), Color(red: 0.38, green: 0.38, blue: 0.42))
        }
    }
}

// MARK: - İzin

struct ApprovalView: View {
    let approval: Approval
    let more: Int
    let actions: NotchActions

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Bird(mood: .alert, size: 64)
                    Badge(color: Palette.amber, symbol: "exclamationmark")
                }
                Text(approval.project).font(.system(size: 14, weight: .bold)).lineLimit(1).padding(.top, 10)
                Text(AgentCatalog.name(approval.agent)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(approval.title)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                if more > 0 {
                    Text("+\(more) istek daha bekliyor").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 140, alignment: .leading)

            VStack(spacing: 10) {
                Viewer(step: approval.preview, cwd: "", prompt: "")
                HStack(spacing: 8) {
                    if approval.onDecision == nil {
                        Button("Terminalde yanıtla") { actions.decide(approval, .terminal) }
                            .buttonStyle(Pill(kind: .ghost))
                    }
                    Spacer()
                    Button("Reddet") { actions.decide(approval, .deny) }
                        .buttonStyle(Pill(kind: .quiet))
                        .keyboardShortcut(.escape, modifiers: [])
                    if !approval.suggestions.isEmpty {
                        Button("Hep izin ver") { actions.decide(approval, .always) }
                            .buttonStyle(Pill(kind: .quiet))
                    }
                    Button("İzin ver") { actions.decide(approval, .allow) }
                        .buttonStyle(Pill(kind: .primary))
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .frame(height: 290)
    }
}

// MARK: - Kuş ve rozet

struct BirdTile: View {
    let session: AgentSession
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Bird(mood: mood, size: size, tint: AgentCatalog.color(session.agent))
                .birdDragSource()
            if let (color, symbol) = badge { Badge(color: color, symbol: symbol) }
        }
    }

    private var mood: Mood {
        switch session.status {
        case .working: .working
        case .waiting: .alert
        case .done: Date().timeIntervalSince(session.updated) < 3 ? .happy : .idle
        case .idle: .idle
        }
    }

    private var badge: (Color, String)? {
        switch session.status {
        case .working: (Palette.blue, "ellipsis")
        case .waiting: (Palette.amber, "exclamationmark")
        case .done: (Palette.green, "checkmark")
        case .idle: nil
        }
    }
}

struct Badge: View {
    let color: Color
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(.black, lineWidth: 2))
    }
}

func relativePath(_ path: String, cwd: String) -> String {
    if !cwd.isEmpty, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
    return StepBuilder.short(path)
}

func statusColor(_ s: AgentSession) -> Color {
    switch s.status {
    case .working: Palette.blue
    case .waiting: Palette.amber
    case .done: Palette.green
    case .idle: .gray
    }
}

// MARK: - Ortak parçalar

struct ConnectCard: View {
    let install: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Bird(mood: .idle, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Claude Code'a bağlı değil").font(.system(size: 13, weight: .semibold))
                Text("Bağlanınca terminallerini burada adım adım izler, izinleri buradan verirsin.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Bağla", action: install).buttonStyle(Pill(kind: .primary))
        }
    }
}

struct Pill: ButtonStyle {
    enum Kind { case primary, quiet, ghost }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: kind == .primary ? .semibold : .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(kind == .primary ? Color.black : Color.white.opacity(kind == .ghost ? 0.6 : 0.95))
            .background(Capsule().fill(kind == .primary ? Color.white : Color.white.opacity(kind == .ghost ? 0 : 0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

enum Palette {
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.30)
    static let green = Color(red: 0.30, green: 0.82, blue: 0.48)
    static let red = Color(red: 0.95, green: 0.36, blue: 0.36)
    static let blue = Color(red: 0.30, green: 0.58, blue: 1.0)
    static let panel = Color(red: 0.075, green: 0.075, blue: 0.085)
    static let editor = Color(red: 0.045, green: 0.047, blue: 0.055)
}

private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// Boş ana sayfada bu haftanın tek satırlık özeti.
struct RecapLine: View {
    @ObservedObject var store: RecapStore
    var body: some View {
        let t = store.week().total
        if t.sessions > 0 {
            Text("Bu hafta \(t.sessions) oturum · \(t.steps) adım · \(t.allowed + t.always) izin")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.top, 2)
        }
    }
}

struct WorktreeChip: View {
    let name: String
    var body: some View {
        Label(name, systemImage: "arrow.triangle.branch")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.white.opacity(0.08)))
            .lineLimit(1)
    }
}

/// Notch'tan yeni Claude Code oturumu: proje + görev + (isteğe bağlı) ayrı git çalışma kopyası.
/// Terminal gerekmez; oturum arka planda çalışır, adımlar ve izinler notch'a düşer.
struct NewSessionView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: SessionStore
    let presetCwd: String
    @State private var cwd = ""
    @State private var task = ""
    @State private var worktree = false
    @State private var error: String?
    @Environment(\.snapshotMode) private var snapshot

    /// Bilinen projeler: proje hafızası + son oturumların klasörleri.
    private var projects: [(name: String, root: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for s in store.sessions {
            let r = ProjectMemory.projectRoot(s.cwd)
            if !ProjectMemory.isContainer(r), seen.insert(r).inserted { out.append(((r as NSString).lastPathComponent, r)) }
        }
        for d in ProjectMemory.allDocs() where !d.root.isEmpty && seen.insert(d.root).inserted { out.append((d.name, d.root)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(Palette.blue)
                Text("Yeni oturum").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.newSessionCwd = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Text("Proje").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Menu {
                    ForEach(projects, id: \.root) { p in Button(p.name) { select(p.root) } }
                    Divider()
                    Button("Klasör seç…") { chooseFolder() }
                } label: {
                    Text(cwd.isEmpty ? "Seç…" : (cwd as NSString).lastPathComponent).font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                let running = projects.isEmpty || cwd.isEmpty ? 0 : store.sessions.filter {
                    $0.project == (cwd as NSString).lastPathComponent && $0.status == .working
                }.count
                if running > 0 {
                    Text("bu projede \(running) oturum çalışıyor").font(.system(size: 10)).foregroundStyle(Palette.amber)
                }
            }
            Group {
                if snapshot {
                    Text(task.isEmpty ? "Görev — ör. \"giriş ekranındaki hatayı düzelt ve testleri çalıştır\"" : task)
                        .foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                } else {
                    TextField("Görev — ör. \"giriş ekranındaki hatayı düzelt ve testleri çalıştır\"", text: $task, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...6)
                }
            }
            .font(.system(size: 12))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
            Toggle(isOn: $worktree) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ayrı çalışma kopyasında (git worktree)").font(.system(size: 12))
                    Text("Aynı projede paralel oturumlar birbirinin dosyalarını ezmez.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.mini)
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(Palette.red) }
            HStack {
                Text("Terminal gerekmez; adımlar ve izinler notch'ta.").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Vazgeç") { model.newSessionCwd = nil }.buttonStyle(Pill(kind: .ghost))
                Button("Başlat", action: start).buttonStyle(Pill(kind: .primary))
                    .disabled(cwd.isEmpty || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { if !presetCwd.isEmpty { select(presetCwd) } }
    }

    private func select(_ root: String) {
        cwd = root
        // Projede çalışan bir oturum varsa yenisi varsayılan olarak ayrı kopyada açılır.
        worktree = AgentRunner.shared.hasActiveSession(in: root)
        error = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { select(url.path) }
    }

    private func start() {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if let err = AgentRunner.shared.start(text, in: cwd, worktree: worktree) {
            error = err
            return
        }
        task = ""
        model.newSessionCwd = nil
        model.showAllSessions = true
    }
}
