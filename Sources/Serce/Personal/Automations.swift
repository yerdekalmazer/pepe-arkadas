import SwiftUI

/// Otomasyonlar: Application Support/Serce/otomasyonlar.json. Her gün (ya da seçili günlerde) belirlenen saatte
/// mesaj sohbete gönderilir, cevap sohbet sekmesinde görünür. Mac o saatte uykudaysa açılınca, en geç 3 saat gecikmeyle çalışır.
@MainActor final class Automations: ObservableObject {
    static let shared = Automations()

    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var message: String
        /// Gece yarısından beri dakika (10:00 = 600).
        var minute: Int
        /// Haftanın günleri, 1 = pazartesi … 7 = pazar. Boşsa her gün.
        var days: [Int] = []
        var enabled = true
        /// En son çalıştığı gün ("yyyy-MM-dd"); aynı gün ikinci kez çalışmaz.
        var lastDay: String?
    }

    @Published private(set) var items: [Item] = []
    private var timer: Timer?
    private var url: URL { Support.dir.appendingPathComponent("otomasyonlar.json") }
    /// Sohbet o an cevap yazıyorsa sıradakiler bekler.
    private var queue: [UUID] = []

    func start() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([Item].self, from: d) { items = v }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        tick()
    }

    @discardableResult
    func add(_ message: String, minute: Int, days: [Int] = []) -> Item {
        var item = Item(message: message, minute: minute, days: days.filter { (1...7).contains($0) }.sorted())
        // Bugünün saati geçmişse bugün çalışmasın; ilk çalışma bir sonraki uygun gün.
        if Self.minutes(Date()) >= minute { item.lastDay = Self.dayKey(Date()) }
        items.append(item)
        sort()
        save()
        return item
    }

    func update(_ item: Item) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        sort()
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func cancel(matching q: String) -> Int {
        let n = TrelloAPI.normalize(q)
        let before = items.count
        items.removeAll { TrelloAPI.normalize($0.message).contains(n) }
        save()
        return before - items.count
    }

    /// Ayarlardaki "Şimdi dene": saati beklemeden gönderir.
    func run(_ item: Item) { fire(item) }

    private func tick() {
        let now = Date(), today = Self.dayKey(now), m = Self.minutes(now)
        let weekday = Self.weekday(now)
        var changed = false
        for i in items.indices where items[i].enabled && items[i].lastDay != today {
            let it = items[i]
            guard it.days.isEmpty || it.days.contains(weekday), m >= it.minute else { continue }
            items[i].lastDay = today
            changed = true
            // Mac kapalıyken kaçırılan, üstünden 3 saatten fazla geçmiş çalışma atlanır.
            if m - it.minute <= 180, !queue.contains(it.id) { queue.append(it.id) }
        }
        if changed { save() }
        drain()
    }

    private func drain() {
        guard !ChatSession.shared.streaming, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        if let item = items.first(where: { $0.id == id }) { fire(item) }
    }

    private func fire(_ item: Item) {
        guard !ChatSession.shared.streaming else {
            if !queue.contains(item.id) { queue.append(item.id) }
            return
        }
        ChatSession.shared.send(item.message)
        SoundEngine.shared.play(.approval)
        CharacterState.shared.emote(.bubble("⏰"))
        AppState.shared.actions.openTab(.chat)
    }

    private func sort() { items.sort { $0.minute < $1.minute } }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: url, options: .atomic) }
    }

    static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// 1 = pazartesi … 7 = pazar.
    static func weekday(_ d: Date) -> Int { (Calendar.current.component(.weekday, from: d) + 5) % 7 + 1 }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static let dayNames = ["Pzt", "Sal", "Çar", "Per", "Cum", "Cmt", "Paz"]

    static func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    static func daysLabel(_ days: [Int]) -> String {
        switch Set(days) {
        case [], Set(1...7): "her gün"
        case Set(1...5): "hafta içi"
        case [6, 7]: "hafta sonu"
        default: days.sorted().map { dayNames[$0 - 1] }.joined(separator: ", ")
        }
    }

    /// "10:00", "9.30", "10" → dakika.
    static func parseTime(_ s: String) -> Int? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(whereSeparator: { ":.".contains($0) }).compactMap { Int($0) }
        guard let h = parts.first, (0...23).contains(h) else { return nil }
        let m = parts.count > 1 ? parts[1] : 0
        guard (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Araçtan gelen gün tarifi: "everyday" | "weekdays" | "weekends" ya da [1…7].
    static func parseDays(_ v: Any?) -> [Int] {
        if let arr = v as? [Int] { return arr }
        switch (v as? String ?? "").lowercased() {
        case "weekdays", "hafta içi": return Array(1...5)
        case "weekends", "hafta sonu": return [6, 7]
        default: return []
        }
    }
}

/// Ayarlar › Kişisel içindeki otomasyon listesi ve ekleme formu.
struct AutomationSettings: View {
    @ObservedObject var automations: Automations
    @State private var message = ""
    @State private var minute = 600
    @State private var days: Set<Int> = []

    var body: some View {
        SettingsGroup(title: "Otomasyonlar",
                      footer: "Saati gelince mesaj sohbete gider, Pepe cevabı sohbet sekmesinde açar. Mac o saatte uykudaysa açılınca çalışır (en geç 3 saat sonra). Sohbette de kurabilirsin: « her sabah 10'da bana günün planını sor ».") {
            if automations.items.isEmpty {
                Text("Henüz otomasyon yok.").foregroundStyle(.secondary)
            }
            ForEach(automations.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Toggle("", isOn: Binding(get: { item.enabled }, set: { var v = item; v.enabled = $0; automations.update(v) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Automations.time(item.minute)) · \(Automations.daysLabel(item.days))")
                            .monospacedDigit().foregroundStyle(.secondary).font(.caption)
                        Text(item.message).lineLimit(2)
                    }
                    Spacer()
                    Button { automations.run(item) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).help("Şimdi dene")
                    Button { automations.remove(item) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Sil")
                }
                .opacity(item.enabled ? 1 : 0.5)
            }
            Divider()
            TextField("Sohbete gidecek mesaj, ör. Bugünün planını çıkar", text: $message, axis: .vertical)
                .lineLimit(1...4)
            HStack {
                DatePicker("Saat", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date() },
                    set: { minute = Automations.minutes($0) }), displayedComponents: .hourAndMinute)
                    .fixedSize()
                Spacer()
                HStack(spacing: 3) {
                    ForEach(1...7, id: \.self) { d in
                        let on = days.contains(d)
                        Button(Automations.dayNames[d - 1]) { if on { days.remove(d) } else { days.insert(d) } }
                            .buttonStyle(.plain)
                            .font(.caption.weight(on ? .semibold : .regular))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(on ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12)))
                    }
                }
                .help("Gün seçmezsen her gün çalışır")
            }
            HStack {
                Text(days.isEmpty ? "Her gün" : Automations.daysLabel(Array(days)).capitalized(with: Locale(identifier: "tr_TR")))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Ekle") {
                    automations.add(message.trimmingCharacters(in: .whitespacesAndNewlines), minute: minute, days: Array(days))
                    message = ""
                    days = []
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
