import SwiftUI

struct StripeData {
    struct Payment {
        var name: String
        var amount: Double
        var currency: String
        var date: Date?
        var succeeded: Bool
    }
    var currency: String
    var todayTotal: Double
    var todayCount: Int
    var failedToday: Int
    var recent: [Payment]
}

/// Stripe: bugünün cirosu ve son ödemeler. Kısıtlı (rk_) ya da gizli (sk_) anahtarla /v1/charges okur.
final class StripePill: PollingPill<StripeData>, PillProvider {
    let id = "stripe"
    let title = "Stripe"
    let subtitle = "Ödemeler"
    let color = Color(hex: 0x635BFF)
    static let keyName = "stripe.key"

    override var configured: Bool { frozen || (Keychain.get(Self.keyName) != nil) }
    var isConfigured: Bool { configured }
    var needsAttention: Bool { (model?.failedToday ?? 0) > 0 }

    override func fetch() async throws -> StripeData {
        let key = Keychain.get(Self.keyName) ?? ""
        let auth = ["Authorization": "Bearer \(key)"]
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        async let today = HTTP.json(URL(string: "https://api.stripe.com/v1/charges?limit=100&created%5Bgte%5D=\(start)")!, headers: auth)
        async let recent = HTTP.json(URL(string: "https://api.stripe.com/v1/charges?limit=4")!, headers: auth)
        return Self.parse(today: try await today, recent: try await recent)
    }

    static let zeroDecimal: Set<String> = ["bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf"]

    static func parse(today: Any, recent: Any) -> StripeData {
        func payments(_ json: Any) -> [StripeData.Payment] {
            ((json as? [String: Any])?.arr("data") ?? []).map { c in
                let cur = (c.str("currency") ?? "usd").lowercased()
                let div = zeroDecimal.contains(cur) ? 1.0 : 100.0
                let net = Double((c.int("amount") ?? 0) - (c.int("amount_refunded") ?? 0)) / div
                let bd = c.dict("billing_details")
                let who = bd.str("name") ?? bd.str("email") ?? c.str("receipt_email") ?? c.str("description") ?? "Ödeme"
                return .init(name: shortName(who), amount: net, currency: cur,
                             date: c.double("created").map { Date(timeIntervalSince1970: $0) },
                             succeeded: c.str("status") == "succeeded")
            }
        }
        let t = payments(today)
        let ok = t.filter(\.succeeded)
        // Birden çok para birimi varsa en sık görüleni gösterilir.
        let counts = Dictionary(grouping: ok, by: \.currency).mapValues(\.count)
        let cur = counts.max { $0.value < $1.value }?.key ?? payments(recent).first?.currency ?? "usd"
        return StripeData(currency: cur,
                          todayTotal: ok.filter { $0.currency == cur }.reduce(0) { $0 + $1.amount },
                          todayCount: ok.count,
                          failedToday: t.filter { !$0.succeeded }.count,
                          recent: payments(recent))
    }

    /// "Sarah Lee" → "Sarah L."; e-posta adresleri olduğu gibi kalır.
    static func shortName(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard parts.count >= 2, !s.contains("@"), let last = parts.last?.first else { return s }
        return "\(parts[0]) \(last)."
    }

    var voiceSummary: String {
        guard configured else { return "Stripe bağlı değil; anahtar girilmemiş." }
        guard let m = model else { return status == .loading ? "Stripe verisi yükleniyor." : "Stripe'a bağlanılamadı." }
        let sym = Fmt.currencySymbol(m.currency)
        var s = m.todayCount == 0 ? "Bugün henüz ödeme yok." :
            "Bugün \(m.todayCount) ödeme, toplam \(Fmt.number(m.todayTotal)) \(sym)."
        if let last = m.recent.first(where: \.succeeded) {
            s += " Son ödeme: \(last.name), \(Fmt.number(last.amount)) \(Fmt.currencySymbol(last.currency))."
        }
        if m.failedToday > 0 { s += " Bugün \(m.failedToday) ödeme başarısız oldu." }
        return s
    }

    func card() -> AnyView {
        AnyView(IntegrationFrame(pill: self, title: title, subtitle: subtitle, color: color,
                                 attention: { $0.failedToday > 0 }) { m in
            VStack(alignment: .leading, spacing: 5) {
                BigValue(value: Fmt.number(m.todayTotal),
                         unit: "\(Fmt.currencySymbol(m.currency)) · bugün \(m.todayCount) ödeme")
                if m.recent.isEmpty { EmptyLine(text: "Henüz ödeme yok") }
                ForEach(Array(m.recent.prefix(4).enumerated()), id: \.offset) { _, p in
                    ServiceRow(dot: p.succeeded ? Palette.green : Palette.red, title: p.name,
                               value: p.succeeded ? "+\(Fmt.number(p.amount))" : "başarısız",
                               valueColor: p.succeeded ? Palette.green : Palette.red,
                               time: Fmt.relative(p.date),
                               link: URL(string: "https://dashboard.stripe.com/payments"))
                }
            }
        })
    }

    func settings() -> AnyView? {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            SecretField(title: "Gizli/kısıtlı anahtar", key: Self.keyName, placeholder: "rk_live_… ya da sk_live_…") { [weak self] in self?.refresh() }
            Text("Kısıtlı anahtar yeterli: yalnızca Charges için okuma izni ver.").font(.caption).foregroundStyle(.secondary)
        })
    }
}
