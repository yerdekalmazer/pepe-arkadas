import SwiftUI

struct GitHubData {
    enum CI { case passing, failing, pending, none }
    struct PR {
        var title: String
        var repo: String
        var number: Int
        var url: URL?
        var apiURL: String
        var updated: Date?
        var ci: CI = .none
    }
    var login: String
    var mine: [PR]
    var reviewRequested: [PR]
    var failing: Int { mine.filter { $0.ci == .failing }.count }
}

/// GitHub: açık PR'ların, senden istenen incelemeler ve son PR'ların CI durumu (check-runs).
final class GitHubPill: PollingPill<GitHubData>, PillProvider {
    let id = "github"
    let title = "GitHub"
    let subtitle = "Pull request'ler"
    let color = Color(hex: 0xEF4444)
    static let keyName = "github.token"

    override var configured: Bool { frozen || (Keychain.get(Self.keyName) != nil) }
    var isConfigured: Bool { configured }
    var needsAttention: Bool { model.map { $0.failing > 0 || !$0.reviewRequested.isEmpty } ?? false }

    private var headers: [String: String] {
        ["Authorization": "Bearer \(Keychain.get(Self.keyName) ?? "")",
         "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
    }

    override func fetch() async throws -> GitHubData {
        let h = headers
        let user = try await HTTP.json(URL(string: "https://api.github.com/user")!, headers: h) as? [String: Any] ?? [:]
        let login = user.str("login") ?? ""
        @Sendable func search(_ q: String) async throws -> Any {
            var c = URLComponents(string: "https://api.github.com/search/issues")!
            c.queryItems = [.init(name: "q", value: q), .init(name: "sort", value: "updated"), .init(name: "per_page", value: "10")]
            return try await HTTP.json(c.url!, headers: h)
        }
        async let mineJSON = search("is:pr is:open author:\(login)")
        async let reviewJSON = search("is:pr is:open review-requested:\(login)")
        var data = GitHubData(login: login, mine: Self.parsePRs(try await mineJSON), reviewRequested: Self.parsePRs(try await reviewJSON))

        // En son güncellenen 3 PR'ın CI durumu
        let top = Array(data.mine.prefix(3))
        let states = await withTaskGroup(of: (Int, GitHubData.CI).self) { g in
            for (i, pr) in top.enumerated() {
                g.addTask { (i, (try? await Self.ci(for: pr.apiURL, headers: h)) ?? .none) }
            }
            var out: [Int: GitHubData.CI] = [:]
            for await (i, s) in g { out[i] = s }
            return out
        }
        for (i, s) in states { data.mine[i].ci = s }
        return data
    }

    private static func ci(for prAPI: String, headers: [String: String]) async throws -> GitHubData.CI {
        guard let u = URL(string: prAPI) else { return .none }
        let pr = try await HTTP.json(u, headers: headers) as? [String: Any] ?? [:]
        guard let sha = pr.dict("head").str("sha"), let repo = pr.dict("base").dict("repo").str("full_name"),
              let url = URL(string: "https://api.github.com/repos/\(repo)/commits/\(sha)/check-runs?per_page=50") else { return .none }
        return parseChecks(try await HTTP.json(url, headers: headers))
    }

    static func parsePRs(_ json: Any) -> [GitHubData.PR] {
        ((json as? [String: Any])?.arr("items") ?? []).map { i in
            let repoURL = i.str("repository_url") ?? ""
            let repo = repoURL.components(separatedBy: "/repos/").last ?? ""
            return .init(title: i.str("title") ?? "", repo: repo, number: i.int("number") ?? 0,
                         url: URL(string: i.str("html_url") ?? ""), apiURL: i.dict("pull_request").str("url") ?? "",
                         updated: Fmt.date(i.str("updated_at")))
        }
    }

    static func parseChecks(_ json: Any) -> GitHubData.CI {
        let runs = (json as? [String: Any])?.arr("check_runs") ?? []
        if runs.isEmpty { return .none }
        let bad: Set<String> = ["failure", "timed_out", "action_required", "startup_failure"]
        if runs.contains(where: { bad.contains($0.str("conclusion") ?? "") }) { return .failing }
        if runs.contains(where: { $0.str("status") != "completed" }) { return .pending }
        return .passing
    }

    static func color(_ ci: GitHubData.CI) -> Color {
        switch ci {
        case .passing: Palette.green
        case .failing: Palette.red
        case .pending: Palette.amber
        case .none: .gray
        }
    }

    var voiceSummary: String {
        guard configured else { return "GitHub bağlı değil; token girilmemiş." }
        guard let m = model else { return status == .loading ? "GitHub verisi yükleniyor." : "GitHub'a bağlanılamadı." }
        var s = "\(m.mine.count) açık pull request'in var."
        if !m.reviewRequested.isEmpty { s += " \(m.reviewRequested.count) tanesinde senden inceleme bekleniyor." }
        if m.failing > 0 { s += " \(m.failing) PR'da CI kırık." }
        else if m.mine.contains(where: { $0.ci == .passing }) { s += " Son PR'larda CI yeşil." }
        return s
    }

    func card() -> AnyView {
        AnyView(IntegrationFrame(pill: self, title: title, subtitle: subtitle, color: color,
                                 attention: { $0.failing > 0 || !$0.reviewRequested.isEmpty }) { m in
            VStack(alignment: .leading, spacing: 5) {
                BigValue(value: "\(m.mine.count)",
                         unit: "açık PR · \(m.reviewRequested.count) inceleme bekliyor")
                let rows = m.reviewRequested.prefix(2).map { ($0, true) } + m.mine.prefix(4).map { ($0, false) }
                if rows.isEmpty { EmptyLine(text: "Açık PR yok") }
                ForEach(Array(rows.prefix(4).enumerated()), id: \.offset) { _, row in
                    let (pr, review) = row
                    ServiceRow(dot: review ? Palette.amber : Self.color(pr.ci), title: pr.title,
                               value: review ? "inceleme" : "\(pr.repo.split(separator: "/").last ?? "")#\(pr.number)",
                               valueColor: review ? Palette.amber : .white.opacity(0.6),
                               time: Fmt.relative(pr.updated), link: pr.url)
                }
            }
        })
    }

    func settings() -> AnyView? {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            SecretField(title: "Kişisel erişim token'ı", key: Self.keyName, placeholder: "github_pat_… ya da ghp_…") { [weak self] in self?.refresh() }
            Text("Fine-grained token: Pull requests ve Checks için okuma izni yeterli.").font(.caption).foregroundStyle(.secondary)
        })
    }
}
