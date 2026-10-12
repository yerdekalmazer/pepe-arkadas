import Foundation

/// Sohbet ve sesli asistanın paylaştığı Claude araç döngüsü (Messages API, ham HTTP — Swift için resmi SDK yok).
/// Kendi araçları + MCP araçları + sunucu araçları (web araması, araç araması) birlikte sunulur.
@MainActor enum ClaudeToolLoop {
    enum Outcome { case answer(String), refusal }

    struct Options {
        var model = "claude-opus-5-5"
        var system: String
        var effort = "medium"
        var maxTokens = 16000
        /// Uygulamanın kendi araç tanımları ve yürütücüsü (sesli asistan araçları gibi).
        var tools: [[String: Any]] = []
        var handler: ((String, [String: Any]) async -> (String, Bool))? = nil
        var webSearch = true
        var useMCP = true
        /// Onay kartında "kim istiyor" satırı.
        var askedBy = "Pepe"
        /// Kullanım sayacında hangi kaleme yazılacağı.
        var purpose: UsageMeter.Purpose = .chat
        /// Proje hafızası ve oturum araçları (yerel; token harcamaz, yalnızca sonuçları bağlama girer).
        var serceTools = true
        /// Araç çalışırken arayüze kısa durum satırı.
        var onProgress: (String) -> Void = { _ in }
    }

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

    /// `messages` döngü boyunca büyür (araç çağrıları, sonuçlar, düşünme blokları olduğu gibi) — çağıran saklayabilir.
    static func run(messages: inout [[String: Any]], _ o: Options) async throws -> Outcome {
        guard let key = Keychain.get("anthropic") else { throw Failure.noKey }
        let mcp = MCPHub.shared
        var tools = o.tools
        if o.serceTools { tools += SerceTools.definitions }
        if o.useMCP { tools += mcp.claudeTools() }
        var o = o
        if o.serceTools { o.system += SerceTools.systemNote() }
        if o.webSearch { tools.append(["type": "web_search_20260209", "name": "web_search", "max_uses": 3]) }

        for _ in 0..<12 {
            let response = try await send(key: key, messages: messages, tools: tools, o)
            let stop = response["stop_reason"] as? String ?? ""
            let content = response["content"] as? [[String: Any]] ?? []
            if stop == "refusal" { return .refusal }
            // Yanıt (düşünme blokları dahil) değiştirilmeden geri konur.
            messages.append(["role": "assistant", "content": content])

            if stop == "tool_use" {
                var results: [[String: Any]] = []
                for block in content where block["type"] as? String == "tool_use" {
                    let id = block["id"] as? String ?? ""
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    var result: [String: Any] = ["type": "tool_result", "tool_use_id": id]
                    if mcp.owns(name) {
                        o.onProgress(progressLabel(name))
                        let (text, isError, images) = await mcp.call(name, input, askedBy: o.askedBy)
                        if images.isEmpty {
                            result["content"] = text
                        } else {
                            result["content"] = [["type": "text", "text": text]] + images.map {
                                ["type": "image", "source": ["type": "base64", "media_type": $0.0, "data": $0.1]]
                            }
                        }
                        if isError { result["is_error"] = true }
                    } else if SerceTools.owns(name) {
                        o.onProgress(SerceTools.progress(name))
                        let (text, isError) = await SerceTools.run(name, input)
                        result["content"] = text
                        if isError { result["is_error"] = true }
                    } else if let handler = o.handler {
                        let (text, isError) = await handler(name, input)
                        result["content"] = text
                        if isError { result["is_error"] = true }
                    } else {
                        result["content"] = "Bilinmeyen araç: \(name)"
                        result["is_error"] = true
                    }
                    results.append(result)
                }
                messages.append(["role": "user", "content": results])
                continue
            }
            if stop == "pause_turn" { continue }

            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return .answer(text)
        }
        return .answer("Bu iş çok fazla adım sürdü; isteği biraz daraltır mısın?")
    }

    private static func progressLabel(_ toolName: String) -> String {
        let parts = toolName.components(separatedBy: "__")
        return parts.count == 2 ? "\(parts[0]) · \(parts[1])" : toolName
    }

    private static func send(key: String, messages: [[String: Any]], tools: [[String: Any]], _ o: Options) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": o.model,
            "max_tokens": o.maxTokens,
            "system": o.system,
            "messages": messages,
            "output_config": ["effort": o.effort],
            // Araçlar + sistem istemi her turda aynı: önbellekten okunur (girdi maliyetinin ~%5'i).
            "cache_control": ["type": "ephemeral"],
        ]
        if !tools.isEmpty { body["tools"] = tools }
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 300
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        // Haiku 5.5'te sunucu tarafı yedek model yok; diğerlerinde ret olursa önerilen modele düşer.
        if !o.model.contains("haiku") {
            body["fallbacks"] = "default"
            r.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.badResponse }
        guard code == 200 else {
            throw Failure.http(code, ((json["error"] as? [String: Any])?["message"] as? String) ?? "")
        }
        UsageMeter.shared.record(model: o.model, usage: json["usage"] as? [String: Any], purpose: o.purpose)
        return json
    }
}
