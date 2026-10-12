import Foundation
import SwiftUI

/// Gün gün küçük sayaçlar: oturum, adım, izin kararları, proje ve ajan dağılımı.
/// ~/Library/Application Support/Serce/haftalik.json — son 8 hafta tutulur, içerik (komut, dosya) kaydedilmez.
struct RecapDay: Codable, Equatable {
    var sessions = 0
    var steps = 0
    var allowed = 0
    var always = 0
    var denied = 0
    var terminal = 0
    var answered = 0
    var projects: [String: Int] = [:]
    var agents: [String: Int] = [:]
}

struct WeekRecap {
    var days: [(Date, RecapDay)]
    var total: RecapDay
    var topProjects: [(String, Int)]
    var agents: [(String, Int)]
}

@MainActor final class RecapStore: ObservableObject {
    static let shared = RecapStore()

    nonisolated(unsafe) static var fileURL = Support.dir.appendingPathComponent("haftalik.json")
    @Published private(set) var days: [String: RecapDay] = [:]
    private var saveWork: DispatchWorkItem?

    private static let keyFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() { reload() }

    func reload() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let d = try? JSONDecoder().decode([String: RecapDay].self, from: data) { days = d } else { days = [:] }
    }

    private func mutate(_ change: (inout RecapDay) -> Void, on date: Date = Date()) {
        let key = Self.keyFormat.string(from: date)
        var day = days[key] ?? RecapDay()
        change(&day)
        days[key] = day
        scheduleSave()
    }

    func recordSession(project: String, agent: String) {
        mutate { $0.sessions += 1; $0.agents[agent, default: 0] += 1; $0.projects[project, default: 0] += 0 }
    }

    func recordStep(project: String) { mutate { $0.steps += 1; $0.projects[project, default: 0] += 1 } }

    func recordDecision(_ d: Decision) {
        mutate {
            switch d {
            case .allow: $0.allowed += 1
            case .always: $0.always += 1
            case .deny: $0.denied += 1
            case .terminal: $0.terminal += 1
            }
        }
    }

    func recordAnswer() { mutate { $0.answered += 1 } }

    /// Son 7 gün (bugün dahil).
    func week(endingAt end: Date = Date()) -> WeekRecap {
        let cal = Calendar.current
        var list: [(Date, RecapDay)] = []
        var total = RecapDay()
        for offset in (0..<7).reversed() {
            guard let date = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: end)) else { continue }
            let d = days[Self.keyFormat.string(from: date)] ?? RecapDay()
            list.append((date, d))
            total.sessions += d.sessions; total.steps += d.steps
            total.allowed += d.allowed; total.always += d.always; total.denied += d.denied
            total.terminal += d.terminal; total.answered += d.answered
            for (k, v) in d.projects { total.projects[k, default: 0] += v }
            for (k, v) in d.agents { total.agents[k, default: 0] += v }
        }
        let top = total.projects.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
        let agents = total.agents.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        return WeekRecap(days: list, total: total, topProjects: Array(top), agents: agents)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func save() {
        // 8 haftadan eskiyi at.
        let limit = Self.keyFormat.string(from: Date().addingTimeInterval(-56 * 86400))
        days = days.filter { $0.key >= limit }
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Test ve anlık görüntü için
    func setForPreview(_ d: [String: RecapDay]) { days = d }

    static func key(_ date: Date) -> String { keyFormat.string(from: date) }

    func registerSettings() {
        SettingsRegistry.shared.add(SettingsSection(id: "ozet", title: "Haftalık özet", icon: "chart.bar", order: 15) {
            AnyView(WeeklyRecapView(store: .shared, dark: false))
        })
    }
}

/// Haftanın özeti: üst sayılar, günlük çubuklar, en çok çalışılan projeler, ajanlar.
struct WeeklyRecapView: View {
    @ObservedObject var store: RecapStore
    var dark = true

    var body: some View {
        let w = store.week()
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                stat("\(w.total.sessions)", "oturum")
                stat("\(w.total.steps)", "adım")
                stat("\(w.total.allowed + w.total.always)", "izin verildi", Palette.green)
                stat("\(w.total.denied)", "reddedildi", Palette.red)
                stat("\(w.total.answered)", "soru cevaplandı", Palette.blue)
            }
            HStack(alignment: .bottom, spacing: 18) {
                chart(w)
                VStack(alignment: .leading, spacing: 6) {
                    Text("En çok çalışılan").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if w.topProjects.isEmpty {
                        Text("Bu hafta henüz iş yok.").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    ForEach(w.topProjects, id: \.0) { name, count in
                        HStack {
                            Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text("\(count) adım").font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                    if !w.agents.isEmpty {
                        Text(w.agents.map { "\(AgentCatalog.name($0.0)) \($0.1)" }.joined(separator: " · "))
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color ?? .primary)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(dark ? Color.white.opacity(0.05) : Color.primary.opacity(0.05)))
    }

    private func chart(_ w: WeekRecap) -> some View {
        let maxSteps = max(1, w.days.map { $0.1.steps }.max() ?? 1)
        let fmt = Date.FormatStyle().weekday(.narrow).locale(Locale(identifier: "tr_TR"))
        return HStack(alignment: .bottom, spacing: 7) {
            ForEach(Array(w.days.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(item.1.steps > 0 ? Palette.blue : Color.gray.opacity(0.25))
                        .frame(width: 16, height: max(3, 70 * CGFloat(item.1.steps) / CGFloat(maxSteps)))
                    Text(item.0.formatted(fmt)).font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 90, alignment: .bottom)
    }
}
