import SwiftUI

/// Sabah brifingi ve haftalık özet — LLM'siz. Kaynaklar: proje md'leri (dünkü oturumlar, açık "Sıradaki"),
/// hatırlatmalar, Trello "Bugün", GitHub ve Cal.com pill'leri (açıksa).
@MainActor final class Briefing: ObservableObject {
    static let shared = Briefing()

    struct Section: Identifiable {
        enum Kind { case lines, trello }
        let id = UUID()
        let title: String
        let icon: String
        var lines: [String]
        var tint: Color = .white
        var kind: Kind = .lines
    }

    @Published private(set) var sections: [Section] = []
    @Published private(set) var title = ""
    @Published var visible = false
    /// Yalnızca anlık görüntü için: proje hafızası yerine örnek "dün çalışılanlar" / "kaldığın yerler".
    var preview: (worked: [String], next: [String])?
    private var timer: Timer?

    var enabled: Bool { UserDefaults.standard.object(forKey: "brifingAcik") as? Bool ?? true }
    /// Brifing saati (dakika cinsinden, varsayılan 09:30).
    var minuteOfDay: Int { UserDefaults.standard.object(forKey: "brifingSaati") as? Int ?? 570 }
    var speak: Bool { UserDefaults.standard.bool(forKey: "brifingSesli") }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.check() } }
        check()
    }

    /// Günde bir kez, ayarlanan saatten sonra Mac ilk kullanıldığında.
    private func check() {
        guard enabled else { return }
        let now = Date(), cal = Calendar.current
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let today = UsageMeter.dayKey(now)
        guard minutes >= minuteOfDay, UserDefaults.standard.string(forKey: "brifingSonGun") != today else { return }
        UserDefaults.standard.set(today, forKey: "brifingSonGun")
        // Cuma akşamı yerine: haftanın ilk brifinginde (pazartesi) geçen haftanın özeti de eklenir.
        show(weekly: cal.component(.weekday, from: now) == 2)
    }

    func show(weekly: Bool = false) {
        build(weekly: weekly)
        visible = true
        AppState.shared.tab = .home
        AppState.shared.actions.expand()
        if speak, VoiceEngine.shared.enabled { VoiceEngine.shared.say(spokenText()) }
    }

    /// Sohbet/ses aracı için düz metin.
    func text(weekly: Bool = false) -> String {
        build(weekly: weekly)
        return ([title] + sections.map { "\($0.title): " + $0.lines.joined(separator: "; ") }).joined(separator: "\n")
    }

    private func spokenText() -> String {
        sections.prefix(4).map { "\($0.title): " + $0.lines.prefix(3).joined(separator: ", ") }.joined(separator: ". ")
    }

    private func build(weekly: Bool) {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMMM EEEE"
        title = "Günaydın — \(f.string(from: Date()))"
        var out: [Section] = []

        let docs = ProjectMemory.allDocs()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let dayLabel = Self.journalDay(yesterday)
        var worked: [String] = []
        var next: [String] = []
        for d in docs where preview == nil {
            let entries = d.section("Oturumlar").components(separatedBy: "### ").filter { $0.hasPrefix(dayLabel) }
            if !entries.isEmpty { worked.append("\(d.name) (\(entries.count) oturum)") }
            let open = d.section("Sıradaki").components(separatedBy: "\n").filter { $0.hasPrefix("- [ ]") }
            if !entries.isEmpty, let first = open.first { next.append("\(d.name): \(first.dropFirst(6))") }
        }
        if let preview { worked = preview.worked; next = preview.next }
        if !worked.isEmpty { out.append(Section(title: "Dün çalışılanlar", icon: "clock.arrow.circlepath", lines: worked, tint: Palette.blue)) }
        if !next.isEmpty { out.append(Section(title: "Kaldığın yerler", icon: "arrow.turn.down.right", lines: next, tint: Palette.green)) }

        let todayReminders = Reminders.shared.upcoming.filter { cal.isDateInToday($0.at) }
        if !todayReminders.isEmpty {
            out.append(Section(title: "Bugünkü hatırlatmalar", icon: "alarm",
                               lines: todayReminders.map { "\(Reminders.format($0.at)) \($0.text)" }, tint: Palette.amber))
        }
        // Trello kendi karosunda (liste çipleri + kartlar); diğer pill'lerin cümleleri satırlara bölünür.
        if let p = AppState.shared.pills.provider("trello") as? TrelloPill, AppState.shared.pills.isActive("trello") {
            out.append(Section(title: "Trello · Kişisel Alan", icon: "rectangle.stack.fill", lines: [p.voiceSummary],
                               tint: p.color, kind: .trello))
        }
        for (id, icon) in [("github", "arrow.triangle.pull"), ("calcom", "calendar")] {
            guard let p = AppState.shared.pills.provider(id), AppState.shared.pills.isActive(id) else { continue }
            let lines = p.voiceSummary.components(separatedBy: ". ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty { out.append(Section(title: p.title, icon: icon, lines: lines, tint: p.color)) }
        }
        if weekly {
            let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
            var counts: [(String, Int)] = []
            for d in docs {
                let n = (0..<7).reduce(0) { acc, i in
                    let label = Self.journalDay(cal.date(byAdding: .day, value: -i - 1, to: Date())!)
                    return acc + d.section("Oturumlar").components(separatedBy: "### ").filter { $0.hasPrefix(label) }.count
                }
                if n > 0 { counts.append((d.name, n)) }
            }
            _ = weekAgo
            if !counts.isEmpty {
                out.append(Section(title: "Geçen hafta", icon: "chart.bar.fill",
                                   lines: counts.sorted { $0.1 > $1.1 }.prefix(6).map { "\($0.0): \($0.1) oturum" },
                                   tint: Color(red: 0.69, green: 0.55, blue: 1.0)))
            }
        }
        if out.isEmpty { out.append(Section(title: "Bugün", icon: "sun.max.fill", lines: ["Kayıtlı bir iş yok; temiz bir sayfa."], tint: Palette.amber)) }
        sections = out
    }

    /// Oturum başlıklarındaki tarih biçimi ("12 Eki 2026").
    static func journalDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
}

struct BriefingCard: View {
    @ObservedObject var briefing: Briefing

    var body: some View {
        if briefing.visible {
            VStack(alignment: .leading, spacing: 12) {
                header
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), spacing: 8, alignment: .top)],
                          alignment: .leading, spacing: 8) {
                    ForEach(briefing.sections) { s in
                        if s.kind == .trello, let pill = AppState.shared.pills.provider("trello") as? TrelloPill {
                            BriefTile(section: s) { TrelloBrief(pill: pill) }
                        } else {
                            BriefTile(section: s) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(s.lines.prefix(4).enumerated()), id: \.offset) { _, l in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Circle().fill(s.tint.opacity(0.7)).frame(width: 4, height: 4).offset(y: -1)
                                            Text(l).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85))
                                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    if s.lines.count > 4 {
                                        Text("+\(s.lines.count - 4) daha").font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.06)))
        }
    }

    private var header: some View {
        let parts = briefing.title.components(separatedBy: " — ")
        return HStack(spacing: 10) {
            Bird(mood: .happy, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(parts.first ?? "Günaydın").font(.system(size: 15, weight: .bold))
                if parts.count > 1 {
                    Text(parts[1]).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { briefing.visible = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Kapat")
        }
    }
}

/// Brifingin tek bölümü: renkli ikon + başlık, altında içerik.
private struct BriefTile<Content: View>: View {
    let section: Briefing.Section
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: section.icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(section.tint)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(section.tint.opacity(0.16)))
                Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.035)))
    }
}

/// Trello karosu: açık listelerin çipleri (emoji ayıklanmış ad + sayı), altında odaktaki listenin ilk kartları.
private struct TrelloBrief: View {
    @ObservedObject var pill: TrelloPill

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let e = pill.error {
                Text(e).font(.system(size: 11)).foregroundStyle(Palette.amber).lineLimit(2)
            } else {
                FlowChips(items: pill.lists.map { (Self.clean($0.name), $0.count, TrelloAPI.normalize($0.name) == TrelloAPI.normalize(pill.focus)) },
                          tint: pill.color)
                ForEach(pill.cards.prefix(3)) { c in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5).fill(pill.color.opacity(0.8)).frame(width: 3, height: 12)
                        Text(Self.clean(c.name)).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if let u = URL(string: c.url) { NSWorkspace.shared.open(u) } }
                }
            }
        }
    }

    /// Liste/kart adlarının başındaki emoji ve boşluğu atar ("📥 Lead Takip" → "Lead Takip").
    static func clean(_ s: String) -> String {
        let trimmed = s.drop { ch in ch.unicodeScalars.allSatisfy { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x2000 || $0 == " " || $0.value == 0xFE0F } }
        let out = String(trimmed).trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? s : out
    }
}

/// Satıra sığdığı kadar çip, taşan alt satıra.
private struct FlowChips: View {
    let items: [(String, Int, Bool)]
    let tint: Color

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Text(item.0).font(.system(size: 10, weight: item.2 ? .semibold : .medium))
                    Text("\(item.1)").font(.system(size: 10, weight: .bold)).foregroundStyle(item.2 ? .white : tint)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .foregroundStyle(.white.opacity(item.2 ? 1 : 0.75))
                .background(Capsule().fill(item.2 ? tint.opacity(0.45) : .white.opacity(0.06)))
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
