import Foundation
import SwiftUI

/// Notch sohbetinin durumu. Geçmiş yalnızca bellekte; "yeni sohbet" temizler.
@MainActor final class ChatSession: ObservableObject {
    static let shared = ChatSession()

    @Published var messages: [ChatMessage] = [] {
        didSet { scheduleSave() }
    }
    private var saveWork: DispatchWorkItem?
    private static var historyURL: URL { Support.dir.appendingPathComponent("sohbet.json") }

    /// Geçmiş diske yazılır (yalnızca metin ve ek adları; ek içerikleri yazılmaz), açılışta geri gelir.
    /// Anlık görüntü ve test modlarında kapatılır; gerçek geçmişin üzerine yazılmasın.
    nonisolated(unsafe) static var persist = true

    private func scheduleSave() {
        guard Self.persist else { return }
        saveWork?.cancel()
        let snapshot = messages.suffix(60).map { ["rol": $0.role.rawValue, "metin": $0.text, "ekler": $0.attachmentNames.joined(separator: "|"),
                                                  "hata": $0.isError ? "1" : ""] }
        let work = DispatchWorkItem {
            if let d = try? JSONSerialization.data(withJSONObject: snapshot) { try? d.write(to: Self.historyURL, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    init() {
        guard Self.persist, let d = try? Data(contentsOf: Self.historyURL),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: String]] else { return }
        messages = arr.compactMap { m in
            guard let role = ChatMessage.Role(rawValue: m["rol"] ?? "") else { return nil }
            var msg = ChatMessage(role: role, text: m["metin"] ?? "")
            msg.attachmentNames = (m["ekler"] ?? "").split(separator: "|").map(String.init)
            msg.isError = m["hata"] == "1"
            return msg
        }
    }
    @Published var draft = ""
    @Published private(set) var streaming = false
    @Published var provider: ChatProvider = .current {
        didSet { ChatProvider.current = provider }
    }
    @Published var model: String = ChatProvider.current.model {
        didSet { provider.model = model }
    }
    /// Ollama / LM Studio'dan çekilen yerel modeller.
    @Published private(set) var localModels: [ChatProvider: [String]] = [:]

    private var task: Task<Void, Never>?

    func select(_ p: ChatProvider, model m: String? = nil) {
        provider = p
        model = m ?? p.model
        if p.isLocal { refreshLocalModels(p) }
    }

    func newChat() {
        task?.cancel()
        messages = []
        draft = ""
        streaming = false
    }

    func stop() { task?.cancel() }

    /// Taslağı ve bekleyen ekleri gönderir.
    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = AppState.shared.attachments
        guard !text.isEmpty || !atts.isEmpty, !streaming else { return }
        draft = ""
        AppState.shared.attachments = []
        send(text, attachments: atts)
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        var user = ChatMessage(role: .user, text: text)
        user.parts = attachments.flatMap(AttachmentReader.parts)
        user.attachmentNames = attachments.map(\.name)
        if text.isEmpty { user.text = "Bu eki incele." }
        messages.append(user)
        messages.append(ChatMessage(role: .assistant, text: ""))
        let history = Self.trimmed(messages.dropLast().filter { !$0.isError })
        let provider = provider, model = model, system = Self.systemPrompt()
        streaming = true
        // Claude seçiliyse ve bağlı MCP aracı varsa araç döngüsü; yoksa düz akış.
        let useTools = provider == .anthropic && MCPHub.shared.toolCount > 0
        task = Task { [weak self] in
            if useTools {
                await self?.runWithTools(model: model, system: system, history: Array(history))
            } else {
                await self?.run(provider: provider, model: model, system: system, history: Array(history))
            }
        }
    }

    /// Sesli asistan gibi arayüzsüz çağıranlar için: tek soru, tam cevap.
    static func complete(_ prompt: String, system extra: String = "") async throws -> String {
        let p = ChatProvider.current
        let req = try ChatRequestBuilder.request(provider: p, model: p.model, system: systemPrompt() + extra,
                                                 messages: [ChatMessage(role: .user, text: prompt)])
        var out = ""
        let parse = ChatRequestBuilder.parser(for: p)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        try await check(resp, bytes)
        for try await line in bytes.lines {
            switch parse(line) {
            case .text(let t): out += t
            case .error(let e): throw ChatRequestBuilder.BuildError(errorDescription: e)
            case .done: return out
            default: break
            }
        }
        return out
    }

    private func run(provider: ChatProvider, model: String, system: String, history: [ChatMessage]) async {
        defer { streaming = false }
        do {
            let req = try ChatRequestBuilder.request(provider: provider, model: model, system: system, messages: history)
            let parse = ChatRequestBuilder.parser(for: provider)
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            try await Self.check(resp, bytes)
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if provider == .anthropic, let u = StreamParser.anthropicUsage(line) {
                    UsageMeter.shared.record(model: model, input: u.input, output: u.output, cacheRead: u.cacheRead,
                                             cacheWrite: u.cacheWrite, purpose: .chat)
                }
                switch parse(line) {
                case .text(let t): appendToLast(t)
                case .error(let e): fail(e); return
                case .refusal: fail("Model bu isteği yanıtlamayı reddetti."); return
                case .done: return
                case nil: break
                }
            }
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch let e as URLError where e.code == .cannotConnectToHost {
            fail("\(provider.title) sunucusuna bağlanılamadı (\(provider.baseURL)). Çalışıyor mu?")
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Token tasarrufu: yalnızca son 16 mesaj gider; ekler (görsel/PDF) yalnızca son kullanıcı mesajında
    /// gönderilir, öncekilerde adlarıyla anılır.
    static func trimmed(_ history: [ChatMessage]) -> [ChatMessage] {
        var h = Array(history.suffix(16))
        while let first = h.first, first.role != .user { h.removeFirst() }
        let lastUser = h.lastIndex { $0.role == .user }
        for i in h.indices where i != lastUser && !h[i].parts.isEmpty {
            h[i].parts = []
            h[i].text += "\n[önceki ek: \(h[i].attachmentNames.joined(separator: ", "))]"
        }
        return h
    }

    /// MCP araçlı Claude turu: akış yerine adım adım; araç çalışırken baloncukta durum satırı görünür.
    private func runWithTools(model: String, system: String, history: [ChatMessage]) async {
        defer { streaming = false }
        var msgs: [[String: Any]] = history.map { ["role": $0.role.rawValue, "content": ChatRequestBuilder.anthropicContent($0)] }
        var o = ClaudeToolLoop.Options(model: model, system: system + "\nBağlı MCP sunucularının araçlarını (GitHub, Notion…) kullanabilirsin; çok araç varsa araç aramasıyla bul. Yazma işlemleri kullanıcıdan notch'ta onay ister.")
        o.askedBy = "Sohbet"
        o.onProgress = { [weak self] label in self?.setLast("⚙︎ \(label)…") }
        do {
            switch try await ClaudeToolLoop.run(messages: &msgs, o) {
            case .answer(let t): setLast(t.isEmpty ? "Tamam." : t)
            case .refusal: setLast(""); fail("Model bu isteği yanıtlamayı reddetti.")
            }
        } catch is CancellationError {
        } catch {
            setLast("")
            fail(error.localizedDescription)
        }
    }

    private func setLast(_ t: String) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].text = t
    }

    private static func check(_ resp: URLResponse, _ bytes: URLSession.AsyncBytes) async throws {
        guard let http = resp as? HTTPURLResponse, http.statusCode != 200 else { return }
        var body = ""
        for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
        var msg = body
        if let d = body.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            msg = ((j["error"] as? [String: Any])?["message"] as? String) ?? (j["error"] as? String) ?? body
        }
        throw ChatRequestBuilder.BuildError(errorDescription: "HTTP \(http.statusCode): \(msg.prefix(300))")
    }

    private func appendToLast(_ t: String) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].text += t
    }

    private func fail(_ msg: String) {
        guard !messages.isEmpty else { return }
        let i = messages.count - 1
        if messages[i].text.isEmpty { messages[i].text = msg } else { messages[i].text += "\n\n" + msg }
        messages[i].isError = true
    }

    func refreshLocalModels(_ p: ChatProvider) {
        let url = URL(string: p.baseURL + (p == .ollama ? "/api/tags" : "/v1/models"))!
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            let names: [String] = p == .ollama
                ? ((j["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                : ((j["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            self?.localModels[p] = names
            if let self, self.provider == p, self.model.isEmpty, let first = names.first { self.model = first }
        }
    }

    // MARK: - Bağlam

    /// Sistem istemi: kim olduğu + o anki ajan oturumları ve pill'lerin kısa özeti ("günümü özetle" için).
    static func systemPrompt() -> String {
        let app = AppState.shared
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMMM yyyy EEEE, HH:mm"
        var s = """
        Sen Serçe'sin: kullanıcının MacBook notch'unda yaşayan küçük bir serçe. Kısa, sıcak ve net cevap ver; \
        kullanıcı hangi dilde yazarsa o dilde (varsayılan Türkçe). Notch dar bir alan: gereksiz uzatma, markdown'u hafif kullan.
        Şu an: \(f.string(from: Date())).
        """
        let sessions = app.store.sessions
        if sessions.isEmpty {
            s += "\n\nŞu an açık ajan oturumu yok."
        } else {
            s += "\n\nKullanıcının kodlama ajanı oturumları (Claude Code vb.):"
            for x in sessions.prefix(8) {
                let status: String = switch x.status {
                case .working: "çalışıyor"
                case .waiting: "izin/yanıt bekliyor"
                case .done: "bitti"
                case .idle: "boşta"
                }
                let done = x.steps.filter { $0.status == .done }.count
                s += "\n- \(x.project): \(status); son eylem: \(x.action); \(done)/\(x.steps.count) adım"
                if !x.prompt.isEmpty { s += "; istek: \"\(x.prompt.prefix(160))\"" }
            }
        }
        let pills = app.pills.active
        if !pills.isEmpty {
            s += "\n\nNotch'taki aktif pill'ler: " + pills.map { "\($0.title) (\($0.subtitle))" }.joined(separator: ", ")
        }
        return s
    }
}
