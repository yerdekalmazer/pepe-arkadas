import SwiftUI

struct N8nData {
    struct Run {
        var workflow: String
        var workflowId: String
        var id: String
        var status: String
        var started: Date?
    }
    var activeCount: Int
    var runs: [Run]
    var todayRuns: Int { runs.filter { Calendar.current.isDateInToday($0.started ?? .distantPast) }.count }
    /// Son çalışması hata veren workflow'lar.
    var failing: [String] {
        var seen = Set<String>(), out: [String] = []
        for r in runs where !seen.contains(r.workflowId) {
            seen.insert(r.workflowId)
            if r.status == "error" || r.status == "crashed" { out.append(r.workflow) }
        }
        return out
    }
}

/// n8n: aktif workflow sayısı ve son çalışmalar (public API v1, X-N8N-API-KEY).
final class N8nPill: PollingPill<N8nData>, PillProvider {
    let id = "n8n"
    let title = "n8n"
    let subtitle = "Workflow'lar"
    let color = Color(hex: 0xFB923C)
    static let keyName = "n8n.key"
    static let urlKey = "n8n.baseURL"

    static var baseURL: String? {
        guard var s = UserDefaults.standard.string(forKey: urlKey), !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasPrefix("http") { s = "https://" + s }
        return s
    }

    override var configured: Bool { frozen || (Keychain.get(Self.keyName) != nil && Self.baseURL != nil) }
    var isConfigured: Bool { configured }
    var needsAttention: Bool { !(model?.failing.isEmpty ?? true) }

    override func fetch() async throws -> N8nData {
        guard let base = Self.baseURL else { throw HTTPError.badBody }
        let h = ["X-N8N-API-KEY": Keychain.get(Self.keyName) ?? ""]
        async let wf = HTTP.json(URL(string: base + "/api/v1/workflows?limit=250")!, headers: h)
        async let ex = HTTP.json(URL(string: base + "/api/v1/executions?limit=20")!, headers: h)
        return Self.parse(workflows: try await wf, executions: try await ex)
    }

    static func parse(workflows: Any, executions: Any) -> N8nData {
        let wfs = (workflows as? [String: Any])?.arr("data") ?? []
        var names: [String: String] = [:]
        for w in wfs { names[w.str("id") ?? "\(w.int("id") ?? 0)"] = w.str("name") ?? "" }
        let runs = ((executions as? [String: Any])?.arr("data") ?? []).map { e -> N8nData.Run in
            let wid = e.str("workflowId") ?? "\(e.int("workflowId") ?? 0)"
            // Eski sürümlerde status yok: finished + stoppedAt'tan çıkar.
            var st = e.str("status") ?? ""
            if st.isEmpty {
                st = e.bool("finished") == true ? "success" : (e.str("stoppedAt") != nil ? "error" : "running")
            }
            return .init(workflow: names[wid] ?? "Workflow \(wid)", workflowId: wid, id: e.str("id") ?? "\(e.int("id") ?? 0)",
                         status: st, started: Fmt.date(e.str("startedAt")))
        }
        return N8nData(activeCount: wfs.filter { $0.bool("active") == true }.count, runs: runs)
    }

    static func color(_ s: String) -> Color {
        switch s {
        case "success": Palette.green
        case "error", "crashed": Palette.red
        case "running", "waiting", "new": Palette.blue
        default: .gray
        }
    }

    static func label(_ s: String) -> String {
        switch s {
        case "success": "başarılı"
        case "error", "crashed": "hata"
        case "running", "new": "çalışıyor"
        case "waiting": "bekliyor"
        case "canceled": "iptal"
        default: s
        }
    }

    var voiceSummary: String {
        guard configured else { return "n8n bağlı değil; adres ya da API anahtarı girilmemiş." }
        guard let m = model else { return status == .loading ? "n8n verisi yükleniyor." : "n8n'e bağlanılamadı." }
        var s = "\(m.activeCount) aktif workflow var, bugün \(m.todayRuns) çalışma görüldü."
        if !m.failing.isEmpty { s += " Son çalışması hata veren: \(m.failing.joined(separator: ", "))." }
        else { s += " Son çalışmalarda hata yok." }
        return s
    }

    func card() -> AnyView {
        AnyView(IntegrationFrame(pill: self, title: title, subtitle: subtitle, color: color,
                                 attention: { !$0.failing.isEmpty }) { m in
            VStack(alignment: .leading, spacing: 5) {
                BigValue(value: "\(m.activeCount)", unit: "aktif workflow · bugün \(m.todayRuns) çalışma")
                if m.runs.isEmpty { EmptyLine(text: "Henüz çalışma yok") }
                ForEach(Array(m.runs.prefix(4).enumerated()), id: \.offset) { _, r in
                    ServiceRow(dot: Self.color(r.status), title: r.workflow, value: Self.label(r.status),
                               valueColor: Self.color(r.status), time: Fmt.relative(r.started),
                               link: Self.baseURL.flatMap { URL(string: "\($0)/workflow/\(r.workflowId)/executions/\(r.id)") })
                }
            }
        })
    }

    func settings() -> AnyView? {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            PlainSettingField(title: "Adres", key: Self.urlKey, placeholder: "https://n8n.sirketin.com") { [weak self] in self?.refresh() }
            SecretField(title: "API anahtarı", key: Self.keyName, placeholder: "Settings → n8n API") { [weak self] in self?.refresh() }
        })
    }
}
