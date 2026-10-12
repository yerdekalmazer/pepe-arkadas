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
    Bağlı MCP sunucularının araçları da var (GitHub, Notion, Linear…); gerekirse araç aramasıyla bul. \
    Güncel bir bilgi (maç sonucu, haber, hava) sorulursa web aramasını kullan.
    - E-posta araçla yalnızca taslak olarak açılır; kullanıcı Gönder'e basmadan gitmez. Bunu kısaca söyle.
    - Bir aracın sonucu hata ise bunu dürüstçe ve kısaca söyle; uydurma.
    """

    func reset() {
        messages = []
        expectsReply = false
    }

    func ask(_ text: String) async throws -> String {
        guard Keychain.get("anthropic") != nil else { throw Failure.noKey }
        if Date().timeIntervalSince(lastTurn) > 180 { messages = [] }
        lastTurn = Date()
        let saved = messages
        messages.append(["role": "user", "content": text])
        var options = ClaudeToolLoop.Options(model: model, system: Self.system)
        // Sesli sohbette gecikme önemli: düşünme açık kalır, derinliği düşük tutulur.
        options.effort = "low"
        options.maxTokens = 4096
        options.tools = VoiceTools.definitions
        options.handler = { name, input in await VoiceTools.run(name, input) }
        options.askedBy = "Sesli asistan"
        do {
            var thread = messages
            let outcome = try await ClaudeToolLoop.run(messages: &thread, options)
            messages = thread
            switch outcome {
            case .refusal:
                messages = saved
                expectsReply = false
                return "Bunu yapamıyorum, kusura bakma."
            case .answer(let answer):
                expectsReply = answer.hasSuffix("?")
                return answer.isEmpty ? "Tamam." : answer
            }
        } catch {
            messages = saved
            throw error
        }
    }
}
