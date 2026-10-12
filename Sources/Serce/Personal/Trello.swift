import AppKit
import SwiftUI

/// Trello: anahtarlar ~/.config/trello/.env'den okunur (sıfır kurulum). Okuma her panoda serbest;
/// yazma yalnızca "Kişisel Alan" ve "VizeX" panolarına ve yalnızca kullanıcı isteyince (onay kartıyla).
enum TrelloAPI {
    struct Card: Identifiable {
        let id: String, name: String, url: String, due: Date?, listName: String
    }
    struct Board { let id: String, name: String }
    struct List { let id: String, name: String }

    enum Failure: LocalizedError {
        case noCredentials, forbidden(String), notFound(String), http(Int)
        var errorDescription: String? {
            switch self {
            case .noCredentials: "Trello anahtarı bulunamadı (~/.config/trello/.env)."
            case .forbidden(let b): "\(b) panosu salt okunur; Pepe yalnızca Kişisel Alan ve VizeX panolarına yazar."
            case .notFound(let s): "\(s) bulunamadı."
            case .http(let c): "Trello yanıt vermedi (\(c))."
            }
        }
    }

    /// Yazılabilir panolar: Kişisel Alan ve VizeX panoları (ada göre; eski VizeX de dahil).
    static func isWritable(_ boardName: String) -> Bool {
        let n = boardName.lowercased()
        return n == "kişisel alan" || n.hasPrefix("vizex")
    }

    static var credentials: (key: String, token: String)? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/trello/.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var env: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) where !line.hasPrefix("#") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { env[kv[0]] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        guard let k = env["TRELLO_KEY"], let t = env["TRELLO_TOKEN"], !k.isEmpty, !t.isEmpty else { return nil }
        return (k, t)
    }

    private static func request(_ method: String, _ path: String, _ query: [String: String] = [:]) async throws -> Any {
        guard let c = credentials else { throw Failure.noCredentials }
        var comps = URLComponents(string: "https://api.trello.com/1" + path)!
        comps.queryItems = (query.merging(["key": c.key, "token": c.token]) { a, _ in a }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.http(code) }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func boards() async throws -> [Board] {
        let arr = try await request("GET", "/members/me/boards", ["filter": "open", "fields": "name"]) as? [[String: Any]] ?? []
        return arr.compactMap { b in (b["id"] as? String).map { Board(id: $0, name: b["name"] as? String ?? "") } }
    }

    static func lists(board: String) async throws -> [List] {
        let arr = try await request("GET", "/boards/\(board)/lists", ["filter": "open", "fields": "name"]) as? [[String: Any]] ?? []
        return arr.compactMap { l in (l["id"] as? String).map { List(id: $0, name: l["name"] as? String ?? "") } }
    }

    static func cards(list: List) async throws -> [Card] {
        let arr = try await request("GET", "/lists/\(list.id)/cards", ["fields": "name,url,due"]) as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return arr.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            return Card(id: id, name: c["name"] as? String ?? "", url: c["url"] as? String ?? "",
                        due: (c["due"] as? String).flatMap { iso.date(from: $0) }, listName: list.name)
        }
    }

    /// Ada göre (büyük/küçük harf ve emoji duyarsız) pano ve liste bulur.
    static func resolve(board: String?, list: String?) async throws -> (Board, List?) {
        let all = try await boards()
        let bq = normalize(board ?? "Kişisel Alan")
        guard let b = all.first(where: { normalize($0.name) == bq }) ?? all.first(where: { normalize($0.name).contains(bq) }) else {
            throw Failure.notFound("'\(board ?? "")' panosu")
        }
        guard let list else { return (b, nil) }
        let lq = normalize(list)
        let ls = try await lists(board: b.id)
        guard let l = ls.first(where: { normalize($0.name) == lq }) ?? ls.first(where: { normalize($0.name).contains(lq) }) else {
            throw Failure.notFound("'\(list)' listesi (\(b.name))")
        }
        return (b, l)
    }

    /// Yazmadan önce: pano izni liste aranmadan kontrol edilir.
    private static func writableBoard(_ board: String?) async throws -> Board {
        let (b, _) = try await resolve(board: board, list: nil)
        guard isWritable(b.name) else { throw Failure.forbidden(b.name) }
        return b
    }

    static func addCard(board: String?, list: String, name: String, desc: String) async throws -> String {
        let b = try await writableBoard(board)
        let (_, l) = try await resolve(board: b.name, list: list)
        guard let l else { throw Failure.notFound(list) }
        let card = try await request("POST", "/cards", ["idList": l.id, "name": name, "desc": desc]) as? [String: Any]
        return "\(b.name) › \(l.name): \"\(name)\" eklendi. \(card?["shortUrl"] as? String ?? "")"
    }

    static func moveCard(board: String?, card: String, toList: String) async throws -> String {
        let b = try await writableBoard(board)
        let (_, target) = try await resolve(board: b.name, list: toList)
        guard let target else { throw Failure.notFound(toList) }
        let q = normalize(card)
        var found: Card?
        for l in try await lists(board: b.id) {
            if let c = try await cards(list: l).first(where: { normalize($0.name).contains(q) }) { found = c; break }
        }
        guard let c = found else { throw Failure.notFound("'\(card)' kartı") }
        _ = try await request("PUT", "/cards/\(c.id)", ["idList": target.id])
        return "\"\(c.name)\": \(c.listName) → \(target.name)"
    }

    /// Emoji ve noktalamayı atıp karşılaştırma için sadeleştirir ("🔥 Bugün" → "bugün").
    static func normalize(_ s: String) -> String {
        String(s.lowercased(with: Locale(identifier: "tr_TR")).unicodeScalars.filter { CharacterSet.letters.union(.decimalDigits).union(.whitespaces).contains($0) })
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Kişisel Alan notch'ta: açık listelerin kart sayıları + seçili listenin kartları (varsayılan Inbox).
/// "Bitti", "Done" ve "KİLL" listeleri sayılmaz.
@MainActor final class TrelloPill: ObservableObject, PillProvider {
    @Published private(set) var lists: [(name: String, count: Int)] = []
    @Published private(set) var cards: [TrelloAPI.Card] = []
    @Published private(set) var error: String?
    @Published var focus: String = UserDefaults.standard.string(forKey: "trelloListe") ?? "Inbox" {
        didSet { UserDefaults.standard.set(focus, forKey: "trelloListe"); refresh() }
    }
    private var timer: Timer?

    var id: String { "trello" }
    var title: String { "Trello" }
    var subtitle: String { error == nil ? "\(TrelloAPI.normalize(focus).capitalized) \(cards.count)" : "bağlanamadı" }
    var color: Color { Color(red: 0.0, green: 0.47, blue: 0.85) }
    var isConfigured: Bool { TrelloAPI.credentials != nil }
    var needsAttention: Bool { cards.contains { ($0.due ?? .distantFuture) < Date() } }

    static func isClosedList(_ name: String) -> Bool {
        let n = TrelloAPI.normalize(name)
        return n.hasPrefix("bitti") || n.contains("done") || n.hasPrefix("kill")
    }

    var voiceSummary: String {
        if let error { return "Trello'ya bağlanamadım: \(error)" }
        let open = lists.map { "\($0.name) \($0.count)" }.joined(separator: ", ")
        let top = cards.prefix(5).map(\.name).joined(separator: ", ")
        return "Kişisel Alan açık listeler: \(open). \(focus) listesinde: \(top.isEmpty ? "kart yok" : top)."
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        Task {
            do {
                let (board, _) = try await TrelloAPI.resolve(board: "Kişisel Alan", list: nil)
                var counts: [(String, Int)] = []
                var focusCards: [TrelloAPI.Card] = []
                for l in try await TrelloAPI.lists(board: board.id) where !Self.isClosedList(l.name) {
                    let cs = try await TrelloAPI.cards(list: l)
                    counts.append((l.name, cs.count))
                    if TrelloAPI.normalize(l.name) == TrelloAPI.normalize(focus) { focusCards = cs }
                }
                lists = counts
                cards = focusCards
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func card() -> AnyView { AnyView(TrelloCard(pill: self)) }

    /// Yalnızca anlık görüntü için: ağa çıkmadan örnek veri.
    func preview(lists: [(String, Int)], cards: [String]) {
        self.lists = lists.map { (name: $0.0, count: $0.1) }
        self.cards = cards.enumerated().map { TrelloAPI.Card(id: "\($0.offset)", name: $0.element, url: "", due: nil, listName: focus) }
        error = nil
    }
}

private struct TrelloCard: View {
    @ObservedObject var pill: TrelloPill

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Bird(mood: pill.needsAttention ? .alert : .idle, size: 52, tint: pill.color)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(pill.color).frame(width: 6, height: 6)
                    Text("Trello").font(.system(size: 12, weight: .bold))
                    Text("Kişisel Alan").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(pill.lists, id: \.name) { l in
                            let on = TrelloAPI.normalize(l.name) == TrelloAPI.normalize(pill.focus)
                            Text("\(l.name) \(l.count)")
                                .font(.system(size: 10, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(on ? pill.color.opacity(0.35) : .white.opacity(0.06)))
                                .onTapGesture { pill.focus = l.name }
                        }
                    }
                }
                if let e = pill.error {
                    Text(e).font(.system(size: 11)).foregroundStyle(Palette.amber)
                } else if pill.cards.isEmpty {
                    Text("Bu liste boş.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(pill.cards.prefix(4)) { c in
                        HStack(spacing: 6) {
                            Circle().fill((c.due ?? .distantFuture) < Date() ? Palette.red : .white.opacity(0.3)).frame(width: 5, height: 5)
                            Text(c.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if let u = URL(string: c.url) { NSWorkspace.shared.open(u) } }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.035)))
    }
}
