import SwiftUI

struct NotionData {
    struct Page {
        var title: String
        var icon: String
        var edited: Date?
        var url: URL?
    }
    var pages: [Page]
    var editedToday: Int { pages.filter { Calendar.current.isDateInToday($0.edited ?? .distantPast) }.count }
}

/// Notion: son düzenlenen sayfalar (POST /v1/search, last_edited_time'a göre).
final class NotionPill: PollingPill<NotionData>, PillProvider {
    let id = "notion"
    let title = "Notion"
    let subtitle = "Son sayfalar"
    let color = Color(hex: 0xA1A1AA)
    static let keyName = "notion.token"

    override var configured: Bool { frozen || (Keychain.get(Self.keyName) != nil) }
    var isConfigured: Bool { configured }

    override func fetch() async throws -> NotionData {
        let body: [String: Any] = ["filter": ["property": "object", "value": "page"],
                                   "sort": ["direction": "descending", "timestamp": "last_edited_time"],
                                   "page_size": 20]
        return Self.parse(try await HTTP.json(URL(string: "https://api.notion.com/v1/search")!, method: "POST",
                                              headers: ["Authorization": "Bearer \(Keychain.get(Self.keyName) ?? "")",
                                                        "Notion-Version": "2022-06-28"], body: body))
    }

    static func parse(_ json: Any) -> NotionData {
        NotionData(pages: ((json as? [String: Any])?.arr("results") ?? []).map { r in
            // Başlık, türü "title" olan özelliktedir; adı sayfadan sayfaya değişir.
            var title = ""
            for (_, v) in r.dict("properties") {
                if let p = v as? [String: Any], p.str("type") == "title" {
                    title = p.arr("title").compactMap { $0.str("plain_text") }.joined()
                }
            }
            let icon = r.dict("icon").str("type") == "emoji" ? (r.dict("icon").str("emoji") ?? "") : ""
            return .init(title: title.isEmpty ? "Adsız" : title, icon: icon,
                         edited: Fmt.date(r.str("last_edited_time")), url: URL(string: r.str("url") ?? ""))
        })
    }

    var voiceSummary: String {
        guard configured else { return "Notion bağlı değil; entegrasyon token'ı girilmemiş." }
        guard let m = model else { return status == .loading ? "Notion verisi yükleniyor." : "Notion'a bağlanılamadı." }
        guard let last = m.pages.first else { return "Notion'da erişilebilen sayfa yok." }
        return "Bugün \(m.editedToday) sayfa düzenlendi. En son \"\(last.title)\", \(Fmt.ago(last.edited))."
    }

    func card() -> AnyView {
        AnyView(IntegrationFrame(pill: self, title: title, subtitle: subtitle, color: color) { m in
            VStack(alignment: .leading, spacing: 5) {
                BigValue(value: "\(m.editedToday)", unit: "sayfa bugün düzenlendi")
                if m.pages.isEmpty { EmptyLine(text: "Paylaşılmış sayfa yok") }
                ForEach(Array(m.pages.prefix(4).enumerated()), id: \.offset) { _, p in
                    ServiceRow(dot: .gray, title: (p.icon.isEmpty ? "" : p.icon + " ") + p.title,
                               time: Fmt.relative(p.edited), link: p.url)
                }
            }
        })
    }

    func settings() -> AnyView? {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            SecretField(title: "Entegrasyon token'ı", key: Self.keyName, placeholder: "ntn_… ya da secret_…") { [weak self] in self?.refresh() }
            Text("notion.so/my-integrations'tan iç entegrasyon aç ve görmek istediğin sayfaları onunla paylaş.")
                .font(.caption).foregroundStyle(.secondary)
        })
    }
}
