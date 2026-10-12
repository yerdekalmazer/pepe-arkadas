import SwiftUI

struct VercelData {
    struct Deployment {
        var name: String
        var state: String
        var created: Date?
        var message: String
        var target: String
        var link: URL?
    }
    var deployments: [Deployment]
    /// Her projenin en son deploy'u hatalıysa o projeler.
    var broken: [String] {
        var seen = Set<String>(), out: [String] = []
        for d in deployments where !seen.contains(d.name) {
            seen.insert(d.name)
            if d.state == "ERROR" { out.append(d.name) }
        }
        return out
    }
}

/// Vercel: son deploy'lar ve durumları (/v6/deployments).
final class VercelPill: PollingPill<VercelData>, PillProvider {
    let id = "vercel"
    let title = "Vercel"
    let subtitle = "Deploy'lar"
    let color = Color(hex: 0x8B5CF6)
    static let keyName = "vercel.token"
    static let teamKey = "vercel.teamId"

    override var configured: Bool { frozen || (Keychain.get(Self.keyName) != nil) }
    var isConfigured: Bool { configured }
    var needsAttention: Bool { !(model?.broken.isEmpty ?? true) }

    override func fetch() async throws -> VercelData {
        var c = URLComponents(string: "https://api.vercel.com/v6/deployments")!
        c.queryItems = [.init(name: "limit", value: "8")]
        if let team = UserDefaults.standard.string(forKey: Self.teamKey), !team.isEmpty {
            c.queryItems?.append(.init(name: "teamId", value: team))
        }
        return Self.parse(try await HTTP.json(c.url!, headers: ["Authorization": "Bearer \(Keychain.get(Self.keyName) ?? "")"]))
    }

    static func parse(_ json: Any) -> VercelData {
        let list = ((json as? [String: Any])?.arr("deployments") ?? []).map { d -> VercelData.Deployment in
            let meta = d.dict("meta")
            let msg = meta.str("githubCommitMessage") ?? meta.str("gitlabCommitMessage") ?? meta.str("bitbucketCommitMessage") ?? ""
            let link = d.str("inspectorUrl").flatMap(URL.init(string:)) ?? d.str("url").flatMap { URL(string: "https://\($0)") }
            return .init(name: d.str("name") ?? "", state: (d.str("state") ?? d.str("readyState") ?? "").uppercased(),
                         created: (d.double("created") ?? d.double("createdAt")).map { Date(timeIntervalSince1970: $0 / 1000) },
                         message: msg.split(separator: "\n").first.map(String.init) ?? "",
                         target: d.str("target") ?? "preview", link: link)
        }
        return VercelData(deployments: list.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) })
    }

    static func label(_ state: String) -> String {
        switch state {
        case "READY": "Hazır"
        case "ERROR": "Hata"
        case "BUILDING": "Derleniyor"
        case "QUEUED", "INITIALIZING": "Sırada"
        case "CANCELED": "İptal"
        default: state.capitalized
        }
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "READY": Palette.green
        case "ERROR": Palette.red
        case "BUILDING", "QUEUED", "INITIALIZING": Palette.amber
        default: .gray
        }
    }

    var voiceSummary: String {
        guard configured else { return "Vercel bağlı değil; token girilmemiş." }
        guard let m = model else { return status == .loading ? "Vercel verisi yükleniyor." : "Vercel'e bağlanılamadı." }
        guard let last = m.deployments.first else { return "Vercel'de henüz deploy yok." }
        var s = "Son deploy \(last.name) projesinde, durumu \(Self.label(last.state).lowercased()), \(Fmt.ago(last.created))."
        if !m.broken.isEmpty { s += " Hatalı projeler: \(m.broken.joined(separator: ", "))." }
        return s
    }

    func card() -> AnyView {
        AnyView(IntegrationFrame(pill: self, title: title, subtitle: subtitle, color: color,
                                 attention: { !$0.broken.isEmpty }) { m in
            VStack(alignment: .leading, spacing: 5) {
                if let last = m.deployments.first {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        BigValue(value: Self.label(last.state), unit: "\(last.name) · \(last.target == "production" ? "prod" : "önizleme")")
                    }
                    .foregroundStyle(Self.color(last.state))
                } else {
                    EmptyLine(text: "Henüz deploy yok")
                }
                ForEach(Array(m.deployments.prefix(4).enumerated()), id: \.offset) { _, d in
                    ServiceRow(dot: Self.color(d.state), title: d.name, detail: d.message,
                               value: Self.label(d.state), valueColor: Self.color(d.state),
                               time: Fmt.relative(d.created), link: d.link)
                }
            }
        })
    }

    func settings() -> AnyView? {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            SecretField(title: "Erişim token'ı", key: Self.keyName, placeholder: "vercel.com/account/tokens") { [weak self] in self?.refresh() }
            PlainSettingField(title: "Takım kimliği (ops.)", key: Self.teamKey, placeholder: "team_…") { [weak self] in self?.refresh() }
        })
    }
}
