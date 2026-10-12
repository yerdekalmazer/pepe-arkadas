import SwiftUI

struct ResendData {
    struct Mail {
        var subject: String
        var to: String
        var event: String
        var created: Date?
        var id: String
    }
    var mails: [Mail]
    var today: [Mail] { mails.filter { Calendar.current.isDateInToday($0.created ?? .distantPast) } }
    var problems: [Mail] {
        mails.filter { ["bounced", "complained", "failed"].contains($0.event) && ($0.created ?? .distantPast) > Date().addingTimeInterval(-86400) }
    }
}

/// Resend: son gönderilen e-postalar ve son olayları (GET /emails).
final class ResendPill: PollingPill<ResendData>, PillProvider {
    let id = "resend"
    let title = "Resend"
    let subtitle = "E-postalar"
    let color = Color(hex: 0x14B8A6)
    static let keyName = "resend.key"

    override var configured: Bool { frozen || (Keychain.get(Self.keyName) != nil) }
    var isConfigured: Bool { configured }
    var needsAttention: Bool { !(model?.problems.isEmpty ?? true) }

    override func fetch() async throws -> ResendData {
        Self.parse(try await HTTP.json(URL(string: "https://api.resend.com/emails?limit=30")!,
                                       headers: ["Authorization": "Bearer \(Keychain.get(Self.keyName) ?? "")"]))
    }

    static func parse(_ json: Any) -> ResendData {
        ResendData(mails: ((json as? [String: Any])?.arr("data") ?? []).map { m in
            .init(subject: m.str("subject") ?? "(konu yok)", to: (m["to"] as? [String])?.first ?? "",
                  event: m.str("last_event") ?? "sent", created: Fmt.date(m.str("created_at")), id: m.str("id") ?? "")
        })
    }

    static func label(_ e: String) -> String {
        switch e {
        case "delivered": "teslim"
        case "opened": "açıldı"
        case "clicked": "tıklandı"
        case "bounced": "geri döndü"
        case "complained": "şikâyet"
        case "delivery_delayed": "gecikti"
        case "scheduled": "planlı"
        case "queued": "sırada"
        case "failed": "başarısız"
        default: "gönderildi"
        }
    }

    static func color(_ e: String) -> Color {
        switch e {
        case "delivered": Palette.green
        case "opened", "clicked": Palette.blue
        case "bounced", "complained", "failed": Palette.red
        case "delivery_delayed": Palette.amber
        default: .gray
        }
    }

    var voiceSummary: String {
        guard configured else { return "Resend bağlı değil; API anahtarı girilmemiş." }
        guard let m = model else { return status == .loading ? "Resend verisi yükleniyor." : "Resend'e bağlanılamadı." }
        var s = "Bugün \(m.today.count) e-posta gönderildi."
        if let last = m.mails.first { s += " Sonuncusu \"\(last.subject)\", durumu \(Self.label(last.event))." }
        if !m.problems.isEmpty { s += " Son bir günde \(m.problems.count) e-posta geri döndü ya da şikâyet aldı." }
        return s
    }

    func card() -> AnyView {
        AnyView(IntegrationFrame(pill: self, title: title, subtitle: subtitle, color: color,
                                 attention: { !$0.problems.isEmpty }) { m in
            VStack(alignment: .leading, spacing: 5) {
                let delivered = m.today.filter { ["delivered", "opened", "clicked"].contains($0.event) }.count
                BigValue(value: "\(m.today.count)", unit: "bugün gönderildi · \(delivered) teslim")
                if m.mails.isEmpty { EmptyLine(text: "Henüz e-posta yok") }
                ForEach(Array(m.mails.prefix(4).enumerated()), id: \.offset) { _, mail in
                    ServiceRow(dot: Self.color(mail.event), title: mail.subject, detail: mail.to,
                               value: Self.label(mail.event), valueColor: Self.color(mail.event),
                               time: Fmt.relative(mail.created), link: URL(string: "https://resend.com/emails/\(mail.id)"))
                }
            }
        })
    }

    func settings() -> AnyView? {
        AnyView(SecretField(title: "API anahtarı", key: Self.keyName, placeholder: "re_…") { [weak self] in self?.refresh() })
    }
}
