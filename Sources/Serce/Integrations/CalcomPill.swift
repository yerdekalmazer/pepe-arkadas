import SwiftUI

struct CalcomData {
    struct Booking {
        var title: String
        var attendee: String
        var start: Date?
        var uid: String
    }
    var upcoming: [Booking]
    var next: Booking? { upcoming.first }
    /// 10 dakika içinde başlayacak toplantı var mı?
    func startingSoon(now: Date = Date()) -> Bool {
        guard let s = next?.start else { return false }
        let d = s.timeIntervalSince(now)
        return d >= -60 && d <= 600
    }
}

/// Cal.com: yaklaşan randevular (API v2 /bookings?status=upcoming).
final class CalcomPill: PollingPill<CalcomData>, PillProvider {
    let id = "calcom"
    let title = "Cal.com"
    let subtitle = "Randevular"
    let color = Color(hex: 0x34D399)
    static let keyName = "calcom.key"

    override var configured: Bool { frozen || (Keychain.get(Self.keyName) != nil) }
    var isConfigured: Bool { configured }
    var needsAttention: Bool { model?.startingSoon() ?? false }

    override func fetch() async throws -> CalcomData {
        var c = URLComponents(string: "https://api.cal.com/v2/bookings")!
        c.queryItems = [.init(name: "status", value: "upcoming"), .init(name: "sortStart", value: "asc"), .init(name: "limit", value: "6")]
        return Self.parse(try await HTTP.json(c.url!, headers: ["Authorization": "Bearer \(Keychain.get(Self.keyName) ?? "")",
                                                               "cal-api-version": "2026-05-01"]))
    }

    static func parse(_ json: Any) -> CalcomData {
        let root = json as? [String: Any] ?? [:]
        // v2: data dizi; bazı sürümler data.bookings, v1 ise kökte bookings döner.
        let list = (root["data"] as? [[String: Any]]) ?? root.dict("data").arr("bookings") + root.arr("bookings")
        let items = list.map { b in
            CalcomData.Booking(title: b.str("title") ?? "Randevu",
                               attendee: b.arr("attendees").first?.str("name") ?? "",
                               start: Fmt.date(b.str("start") ?? b.str("startTime")),
                               uid: b.str("uid") ?? "")
        }
        let now = Date().addingTimeInterval(-3600)
        return CalcomData(upcoming: items.filter { ($0.start ?? .distantFuture) > now }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) })
    }

    var voiceSummary: String {
        guard configured else { return "Cal.com bağlı değil; API anahtarı girilmemiş." }
        guard let m = model else { return status == .loading ? "Cal.com verisi yükleniyor." : "Cal.com'a bağlanılamadı." }
        guard let n = m.next else { return "Yaklaşan randevu yok." }
        var s = "Sıradaki randevu \(Fmt.dayWord(n.start)) \(Fmt.clock(n.start)): \(n.title)"
        if !n.attendee.isEmpty { s += ", \(n.attendee) ile" }
        s += "."
        if m.upcoming.count > 1 { s += " Toplam \(m.upcoming.count) yaklaşan randevu var." }
        return s
    }

    func card() -> AnyView {
        let color = self.color
        return AnyView(IntegrationFrame(pill: self, title: title, subtitle: subtitle, color: color,
                                 attention: { $0.startingSoon() }) { m in
            VStack(alignment: .leading, spacing: 5) {
                if let n = m.next {
                    BigValue(value: Fmt.clock(n.start), unit: "\(Fmt.dayWord(n.start)) · \(n.title)")
                } else {
                    BigValue(value: "Boş", unit: "yaklaşan randevu yok")
                }
                ForEach(Array(m.upcoming.prefix(4).enumerated()), id: \.offset) { i, b in
                    ServiceRow(dot: i == 0 ? color : .gray, title: b.title, detail: b.attendee,
                               value: "\(Fmt.dayWord(b.start)) \(Fmt.clock(b.start))", valueColor: .white.opacity(0.7),
                               link: b.uid.isEmpty ? nil : URL(string: "https://app.cal.com/booking/\(b.uid)"))
                }
            }
        })
    }

    func settings() -> AnyView? {
        AnyView(SecretField(title: "API anahtarı", key: Self.keyName, placeholder: "cal_live_…") { [weak self] in self?.refresh() })
    }
}
