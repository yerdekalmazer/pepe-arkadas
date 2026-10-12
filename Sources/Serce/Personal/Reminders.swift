import AppKit
import SwiftUI

/// Hatırlatmalar: Application Support/Serce/hatirlatmalar.json. Zamanı gelince ada açılır, kuş haber verir.
/// Kurmak sohbet/sesle olur; tetiklenmek token harcamaz.
@MainActor final class Reminders: ObservableObject {
    static let shared = Reminders()

    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var at: Date
        var project: String?
        var fired = false
    }

    @Published private(set) var items: [Item] = []
    /// Tetiklenmiş, kullanıcı kapatmamış hatırlatmalar (ana sayfanın tepesinde).
    @Published private(set) var due: [Item] = []
    private var timer: Timer?
    private var url: URL { Support.dir.appendingPathComponent("hatirlatmalar.json") }

    func start() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([Item].self, from: d) { items = v }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        tick()
    }

    @discardableResult
    func add(_ text: String, at: Date, project: String? = nil) -> Item {
        let item = Item(text: text, at: at, project: project)
        items.append(item)
        items.sort { $0.at < $1.at }
        save()
        return item
    }

    func cancel(matching q: String) -> Int {
        let n = TrelloAPI.normalize(q)
        let before = items.count
        items.removeAll { !$0.fired && TrelloAPI.normalize($0.text).contains(n) }
        save()
        return before - items.count
    }

    func dismiss(_ item: Item) { due.removeAll { $0.id == item.id } }

    /// 10 dakika ertele.
    func snooze(_ item: Item) {
        dismiss(item)
        add(item.text, at: Date().addingTimeInterval(600), project: item.project)
    }

    var upcoming: [Item] { items.filter { !$0.fired } }

    /// Yalnızca anlık görüntü için.
    func showForSnapshot(_ text: String, project: String?) {
        due = [Item(text: text, at: Date(), project: project, fired: true)]
    }

    private func tick() {
        let now = Date()
        var changed = false
        for i in items.indices where !items[i].fired && items[i].at <= now {
            items[i].fired = true
            changed = true
            due.append(items[i])
            SoundEngine.shared.play(.approval)
            CharacterState.shared.emote(.bubble("⏰"))
            AppState.shared.tab = .home
            AppState.shared.actions.expand()
        }
        // Bir haftadan eski tetiklenmişler temizlenir.
        let old = items.count
        items.removeAll { $0.fired && $0.at < now.addingTimeInterval(-7 * 86400) }
        if changed || old != items.count { save() }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: url, options: .atomic) }
    }

    static func format(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'bugün' HH:mm" : (Calendar.current.isDateInTomorrow(d) ? "'yarın' HH:mm" : "d MMMM EEEE HH:mm")
        return f.string(from: d)
    }

    /// "2026-10-13 10:00" ya da ISO 8601 → Date (yerel saat).
    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }
}

/// Ana sayfanın tepesinde: zamanı gelen hatırlatma.
struct ReminderBanner: View {
    @ObservedObject var reminders: Reminders

    var body: some View {
        if let r = reminders.due.first {
            HStack(spacing: 10) {
                Image(systemName: "alarm.fill").foregroundStyle(Palette.amber)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.text).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    if let p = r.project { Text(p).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("10 dk") { reminders.snooze(r) }.buttonStyle(Pill(kind: .quiet))
                Button("Tamam") { reminders.dismiss(r) }.buttonStyle(Pill(kind: .primary))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.amber.opacity(0.12)))
        }
    }
}
