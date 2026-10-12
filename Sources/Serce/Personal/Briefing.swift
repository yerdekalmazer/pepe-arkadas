import SwiftUI

/// Sabah brifingi ve haftalık özet — LLM'siz. Kaynaklar: proje md'leri (dünkü oturumlar, açık "Sıradaki"),
/// hatırlatmalar, Trello "Bugün", GitHub ve Cal.com pill'leri (açıksa).
@MainActor final class Briefing: ObservableObject {
    static let shared = Briefing()

    struct Section: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        var lines: [String]
    }

    @Published private(set) var sections: [Section] = []
    @Published private(set) var title = ""
    @Published var visible = false
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
        for d in docs {
            let entries = d.section("Oturumlar").components(separatedBy: "### ").filter { $0.hasPrefix(dayLabel) }
            if !entries.isEmpty { worked.append("\(d.name) (\(entries.count) oturum)") }
            let open = d.section("Sıradaki").components(separatedBy: "\n").filter { $0.hasPrefix("- [ ]") }
            if !entries.isEmpty, let first = open.first { next.append("\(d.name): \(first.dropFirst(6))") }
        }
        if !worked.isEmpty { out.append(Section(title: "Dün çalışılanlar", icon: "clock.arrow.circlepath", lines: worked)) }
        if !next.isEmpty { out.append(Section(title: "Kaldığın yerler", icon: "arrow.turn.down.right", lines: next)) }

        let todayReminders = Reminders.shared.upcoming.filter { cal.isDateInToday($0.at) }
        if !todayReminders.isEmpty {
            out.append(Section(title: "Bugünkü hatırlatmalar", icon: "alarm",
                               lines: todayReminders.map { "\(Reminders.format($0.at)) \($0.text)" }))
        }
        for id in ["trello", "github", "calcom"] {
            guard let p = AppState.shared.pills.provider(id), AppState.shared.pills.isActive(id) else { continue }
            let s = p.voiceSummary
            if !s.isEmpty { out.append(Section(title: p.title, icon: "capsule", lines: [s])) }
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
                out.append(Section(title: "Geçen hafta", icon: "calendar",
                                   lines: counts.sorted { $0.1 > $1.1 }.prefix(6).map { "\($0.0): \($0.1) oturum" }))
            }
        }
        if out.isEmpty { out.append(Section(title: "Bugün", icon: "sun.max", lines: ["Kayıtlı bir iş yok; temiz bir sayfa."])) }
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "sun.max.fill").foregroundStyle(Palette.amber)
                    Text(briefing.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { briefing.visible = false } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(briefing.sections) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(s.title, systemImage: s.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(s.lines.prefix(4), id: \.self) { l in
                            Text("· " + l).font(.system(size: 12)).lineLimit(2)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        }
    }
}
