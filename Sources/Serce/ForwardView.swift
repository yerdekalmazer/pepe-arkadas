import SwiftUI

/// Bir oturumdaki sorunu ya da sonucu başka bir ajana aktarmak: son yanıt, hata veren adım, görev ve senin notun
/// tek mesajda birleşir; var olan bir oturuma gider (çalışıyorsa sıraya girer) ya da başka bir ajanla yeni oturum açar.
struct ForwardView: View {
    let source: AgentSession
    @ObservedObject var model: NotchModel
    @ObservedObject var store: SessionStore
    @State private var parts: Set<Forward.Part> = []
    @State private var note = ""
    @State private var target: Forward.Target?
    @State private var error: String?
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let available = Forward.available(in: source)
        let targets = Forward.targets(for: source, in: store)
        let chosen = target ?? Forward.defaultTarget(for: source, in: store)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrowshape.turn.up.right.fill").foregroundStyle(Palette.blue)
                Text("Başka ajana aktar").font(.system(size: 13, weight: .semibold))
                Text("\(source.project) · \(source.agentName)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { model.forwardFrom = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Text("İçerik").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                ForEach(available, id: \.self) { p in
                    let on = parts.contains(p)
                    Button { if on { parts.remove(p) } else { parts.insert(p) } } label: {
                        Label(p.title, systemImage: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: on ? .semibold : .regular))
                    }
                    .buttonStyle(Pill(kind: .quiet))
                }
                if available.isEmpty {
                    Text("Bu oturumda aktarılacak yanıt ya da adım yok; notunu yazabilirsin.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("Kime").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                if snapshot {
                    // ImageRenderer menüyü çizemez.
                    Text(chosen?.title(in: store) ?? "Hedef yok").font(.system(size: 12, weight: .medium))
                } else {
                Menu {
                    let existing = targets.filter { if case .session = $0 { return true }; return false }
                    ForEach(existing, id: \.id) { t in Button(t.title(in: store)) { target = t } }
                    if !existing.isEmpty { Divider() }
                    ForEach(targets.filter { if case .new = $0 { return true }; return false }, id: \.id) { t in
                        Button(t.title(in: store)) { target = t }
                    }
                } label: {
                    Text(chosen?.title(in: store) ?? "Hedef yok").font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                }
                Spacer()
            }
            Group {
                if snapshot {
                    Text(note.isEmpty ? "Ne yapsın? ör. \"Bu hatayı düzelt\", \"Bu planı gözden geçir\"" : note)
                        .foregroundStyle(.white.opacity(note.isEmpty ? 0.35 : 1))
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                } else {
                    TextField("Ne yapsın? ör. \"Bu hatayı düzelt\", \"Bu planı gözden geçir\"", text: $note, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...4)
                }
            }
            .font(.system(size: 12))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
            Text(Forward.message(from: source, parts: parts, note: note))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.03)))
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(Palette.red) }
            HStack {
                Text(chosen.map { Forward.hint($0, in: store) } ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Vazgeç") { model.forwardFrom = nil }.buttonStyle(Pill(kind: .ghost))
                Button("Aktar") { send(chosen) }.buttonStyle(Pill(kind: .primary))
                    .disabled(chosen == nil || (parts.isEmpty && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .onAppear { parts = Forward.defaultParts(in: source) }
    }

    private func send(_ t: Forward.Target?) {
        guard let t else { return }
        let text = Forward.message(from: source, parts: parts, note: note)
        if let err = Forward.send(text, from: source, to: t, in: store) {
            error = err
            return
        }
        model.forwardFrom = nil
        if case .session(let id) = t {
            model.pinnedStep = nil
            model.selectedSession = id
        } else {
            model.selectedSession = nil
            model.showAllSessions = true
        }
    }
}

/// Aktarma mantığı; görünüm ve Pepe'nin sohbet aracı ortak kullanır.
@MainActor enum Forward {
    enum Part: String, Hashable, CaseIterable {
        case reply, failed, prompt
        var title: String {
            switch self {
            case .reply: "Son yanıt"
            case .failed: "Hata veren adım"
            case .prompt: "Görev"
            }
        }
    }

    enum Target: Hashable {
        case session(String)
        case new(RunnableAgent)

        var id: String {
            switch self {
            case .session(let s): s
            case .new(let a): "yeni-" + a.rawValue
            }
        }

        @MainActor func title(in store: SessionStore) -> String {
            switch self {
            case .session(let id):
                guard let s = store.sessions.first(where: { $0.id == id }) else { return "Oturum" }
                return "\(s.project) · \(s.agentName)\(s.worktree.map { " · \($0)" } ?? "")\(s.status == .working ? " (çalışıyor)" : "")"
            case .new(let a):
                return "Yeni \(a.title) oturumu (aynı projede)"
            }
        }
    }

    static func available(in s: AgentSession) -> [Part] {
        var out: [Part] = []
        if !s.lastReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.reply) }
        if failedStep(in: s) != nil { out.append(.failed) }
        if !s.prompt.isEmpty { out.append(.prompt) }
        return out
    }

    /// Hata varsa hata ve görev; yoksa son yanıt.
    static func defaultParts(in s: AgentSession) -> Set<Part> {
        let a = available(in: s)
        if a.contains(.failed) { return Set([.failed, .prompt].filter(a.contains)) }
        return a.contains(.reply) ? [.reply] : Set(a)
    }

    static func failedStep(in s: AgentSession) -> Step? {
        s.steps.last { step in
            if step.status == .failed { return true }
            if case .terminal(_, _, true) = step.content { return true }
            return false
        }
    }

    /// Yazılabilen diğer oturumlar (önce aynı projedekiler), sonra kurulu ajanlarla yeni oturum.
    static func targets(for source: AgentSession, in store: SessionStore) -> [Target] {
        let others = store.sessions.filter { $0.id != source.id && AgentRunner.canWrite($0.agent) }
            .sorted { ($0.project == source.project ? 0 : 1, $1.updated) < ($1.project == source.project ? 0 : 1, $0.updated) }
        return others.map { .session($0.id) } + RunnableAgent.allCases.filter(\.installed).map { .new($0) }
    }

    /// Aynı projede başka bir ajanın oturumu varsa o; yoksa kaynaktan farklı bir ajanla yeni oturum.
    static func defaultTarget(for source: AgentSession, in store: SessionStore) -> Target? {
        if let s = store.sessions.first(where: { $0.id != source.id && $0.project == source.project
            && $0.agent != source.agent && AgentRunner.canWrite($0.agent) }) {
            return .session(s.id)
        }
        let other = RunnableAgent.allCases.first { $0.installed && $0.rawValue != source.agent } ?? .claude
        return .new(other)
    }

    static func hint(_ t: Target, in store: SessionStore) -> String {
        switch t {
        case .session(let id):
            let s = store.sessions.first { $0.id == id }
            return s?.status == .working || AgentRunner.shared.isRunning(id) ? "Oturum çalışıyor; bitince gönderilir." : "Mesaj bu oturuma gider."
        case .new(let a):
            return a == .claude ? "Yeni oturum terminalsiz açılır." : "Yeni oturum terminalsiz açılır; izinleri varsayılan Mod belirler."
        }
    }

    static func message(from s: AgentSession, parts: Set<Part>, note: String) -> String {
        var blocks: [String] = []
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { blocks.append(n) }
        var quoted: [String] = []
        if parts.contains(.prompt), !s.prompt.isEmpty { quoted.append("Görev:\n" + clip(s.prompt, 1500)) }
        if parts.contains(.failed), let f = failedStep(in: s) { quoted.append("Hata veren adım:\n" + clip(text(of: f), 4000)) }
        if parts.contains(.reply), !s.lastReply.isEmpty { quoted.append("Son yanıt:\n" + clip(s.lastReply, 4000)) }
        if !quoted.isEmpty {
            let header = "— \(s.project) projesindeki \(s.agentName) oturumundan aktarıldı (klasör: \(s.cwd)) —"
            blocks.append(([header] + quoted).joined(separator: "\n\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Var olan oturuma gönderir (çalışıyorsa sıraya alır) ya da aynı projede yeni oturum açar.
    static func send(_ text: String, from source: AgentSession, to t: Target, in store: SessionStore) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Gönderilecek bir şey yok." }
        switch t {
        case .session(let id):
            guard let s = store.sessions.first(where: { $0.id == id }) else { return "Hedef oturum artık yok." }
            return ComposerStore.shared.enqueue(text, for: s)
        case .new(let agent):
            let root = ProjectMemory.projectRoot(source.cwd)
            let dir = FileManager.default.fileExists(atPath: root) ? root : source.cwd
            return AgentRunner.shared.start(text, in: dir, worktree: AgentRunner.shared.hasActiveSession(in: dir), agent: agent)
        }
    }

    static func text(of step: Step) -> String {
        let head = [step.title, step.subtitle].filter { !$0.isEmpty }.joined(separator: " · ")
        let body: String
        switch step.content {
        case .terminal(let cmd, let out, _): body = "$ \(cmd)\n\(out)"
        case .code(let lines):
            body = lines.map { ($0.kind == .added ? "+ " : $0.kind == .removed ? "- " : "  ") + $0.text }.joined(separator: "\n")
        case .text(let t): body = t
        }
        return [head, body].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "\n…" : s }
}
