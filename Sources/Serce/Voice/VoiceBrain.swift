import Foundation

/// Sesli asistanın aklı: Claude Messages API, elle yürütülen araç döngüsü.
/// Sesin kendisi hiçbir yere gitmez; yalnızca yazıya dökülmüş cümle ve araçların okuduğu veri gönderilir.
@MainActor final class VoiceBrain {
    static let models: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5"),
    ]

    enum Failure: LocalizedError {
        case noKey, http(Int, String), badResponse
        var errorDescription: String? {
            switch self {
            case .noKey: "Anthropic anahtarı yok. Ayarlar → Sohbet'ten ekle."
            case .http(let c, let m): "Claude yanıt vermedi (\(c)). \(m)"
            case .badResponse: "Claude'un yanıtı okunamadı."
            }
        }
    }

    private var messages: [[String: Any]] = []
    private var lastTurn = Date.distantPast
    /// Son yanıt bir soruyla bittiyse motor uyandırma kelimesi beklemeden tekrar dinler.
    private(set) var expectsReply = false

    var model: String { UserDefaults.standard.string(forKey: "sesModeli") ?? "claude-opus-5-5" }

    private static let system = """
    Sen Serçe'sin: kullanıcının Mac'inde, ekranın tepesindeki çentikte yaşayan küçük, sıcakkanlı bir serçe. \
    Kullanıcı seninle sesli konuşuyor; cevapların yüksek sesle okunacak.
    - Kısa konuş: çoğu zaman 1-2 cümle. Markdown, liste, emoji, bağlantı kullanma; rakamları doğal söyle.
    - Kullanıcı hangi dilde konuştuysa o dilde cevap ver (Türkçe ya da İngilizce).
    - Bir iş için bilgi eksikse tek bir kısa soru sor; kullanıcı cevap verince devam et.
    - Ajan oturumları, pill verileri (Stripe, GitHub, Vercel…), müzik, uygulama açma, e-posta için araçlarını kullan. \
    Güncel bir bilgi (maç sonucu, haber, hava) sorulursa web aramasını kullan.
    - E-posta araçla yalnızca taslak olarak açılır; kullanıcı Gönder'e basmadan gitmez. Bunu kısaca söyle.
    - Bir aracın sonucu hata ise bunu dürüstçe ve kısaca söyle; uydurma.
    """

    func reset() {
        messages = []
        expectsReply = false
    }

    func ask(_ text: String) async throws -> String {
        guard let key = Keychain.get("anthropic") else { throw Failure.noKey }
        if Date().timeIntervalSince(lastTurn) > 180 { messages = [] }
        lastTurn = Date()
        messages.append(["role": "user", "content": text])

        for _ in 0..<8 {
            let response = try await send(key: key)
            let stop = response["stop_reason"] as? String ?? ""
            let content = response["content"] as? [[String: Any]] ?? []

            if stop == "refusal" {
                messages.removeLast()
                expectsReply = false
                return "Bunu yapamıyorum, kusura bakma."
            }
            // Düşünme blokları dahil yanıtı olduğu gibi geri koy; bir sonraki istek onları bekler.
            messages.append(["role": "assistant", "content": content])

            if stop == "tool_use" {
                var results: [[String: Any]] = []
                for block in content where block["type"] as? String == "tool_use" {
                    let id = block["id"] as? String ?? ""
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    let (output, isError) = await VoiceTools.run(name, input)
                    var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": output]
                    if isError { r["is_error"] = true }
                    results.append(r)
                }
                messages.append(["role": "user", "content": results])
                continue
            }
            if stop == "pause_turn" { continue }

            let answer = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            expectsReply = answer.hasSuffix("?")
            return answer.isEmpty ? "Tamam." : answer
        }
        expectsReply = false
        return "Bu biraz uzun sürdü, bir daha dener misin?"
    }

    private func send(key: String) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": Self.system,
            "tools": VoiceTools.definitions + [["type": "web_search_20260209", "name": "web_search", "max_uses": 3]],
            "messages": messages,
            // Sesli sohbette gecikme önemli: düşünme açık kalır, derinliği düşük tutulur.
            "output_config": ["effort": "low"],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Haiku 5.5'te sunucu tarafı yedek model yok; diğerlerinde ret olursa önerilen modele düşer.
        if !model.contains("haiku") {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.badResponse }
        guard code == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
            if !messages.isEmpty, (messages.last?["role"] as? String) == "user" { messages.removeLast() }
            throw Failure.http(code, msg)
        }
        return json
    }
}
