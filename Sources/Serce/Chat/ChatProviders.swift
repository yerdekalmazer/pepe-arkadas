import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Sohbet sağlayıcıları. Anahtarlar Keychain'de: "anthropic", "openai", "gemini".
/// Yerel sunucuların adresleri UserDefaults'ta: "ollamaURL", "lmstudioURL".
enum ChatProvider: String, CaseIterable, Identifiable {
    case anthropic, openai, gemini, ollama, lmstudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Claude"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        }
    }

    /// Önerilen modeller; ayarlardan elle başka kimlik de yazılabilir.
    var suggestedModels: [String] {
        switch self {
        case .anthropic: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        case .openai: ["gpt-5", "gpt-5-mini"]
        case .gemini: ["gemini-2.5-pro", "gemini-2.5-flash"]
        case .ollama, .lmstudio: []
        }
    }

    var keychainKey: String? {
        switch self {
        case .anthropic: "anthropic"
        case .openai: "openai"
        case .gemini: "gemini"
        case .ollama, .lmstudio: nil
        }
    }

    var isLocal: Bool { self == .ollama || self == .lmstudio }

    var baseURL: String {
        switch self {
        case .ollama: UserDefaults.standard.string(forKey: "ollamaURL").flatMap { $0.isEmpty ? nil : $0 } ?? "http://localhost:11434"
        case .lmstudio: UserDefaults.standard.string(forKey: "lmstudioURL").flatMap { $0.isEmpty ? nil : $0 } ?? "http://localhost:1234"
        case .anthropic: "https://api.anthropic.com"
        case .openai: "https://api.openai.com"
        case .gemini: "https://generativelanguage.googleapis.com"
        }
    }

    var isConfigured: Bool { isLocal || keychainKey.flatMap(Keychain.get) != nil }

    /// Seçili model (sağlayıcı başına UserDefaults "sohbetModeli.<id>").
    var model: String {
        get {
            UserDefaults.standard.string(forKey: "sohbetModeli.\(rawValue)").flatMap { $0.isEmpty ? nil : $0 }
                ?? suggestedModels.first ?? ""
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "sohbetModeli.\(rawValue)") }
    }

    static var current: ChatProvider {
        get { ChatProvider(rawValue: UserDefaults.standard.string(forKey: "sohbetSaglayici") ?? "") ?? .anthropic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sohbetSaglayici") }
    }
}

/// Bir mesajın parçası. Ekler gönderilmeden önce buna çevrilir.
enum ChatPart: Equatable {
    case text(String)
    case image(mime: String, base64: String)
    /// PDF: Claude ve Gemini doğrudan okur; diğerlerine çıkarılmış metin gider.
    case pdf(name: String, base64: String, text: String)
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    var parts: [ChatPart] = []
    /// Kullanıcının mesajındaki eklerin adları (çip olarak gösterilir).
    var attachmentNames: [String] = []
    var isError = false
}

enum AttachmentReader {
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h",
        "cpp", "m", "cs", "php", "html", "css", "scss", "json", "yaml", "yml", "toml", "xml", "csv", "sh", "zsh",
        "sql", "env", "ini", "log", "vue", "svelte", "dart", "lua",
    ]

    /// Eki API'ye gidecek parçaya çevirir. Okunamayan dosya yalnızca adıyla anılır.
    static func parts(for a: Attachment) -> [ChatPart] {
        switch a.kind {
        case .text(let s):
            return [.text("[\(a.name)]\n\(s)")]
        case .image(let data):
            return [imagePart(data)].compactMap { $0 }
        case .file(let url):
            let ext = url.pathExtension.lowercased()
            if ext == "pdf", let data = try? Data(contentsOf: url) {
                let text = PDFDocument(data: data)?.string ?? ""
                return [.pdf(name: url.lastPathComponent, base64: data.base64EncodedString(), text: String(text.prefix(200_000)))]
            }
            if let type = UTType(filenameExtension: ext), type.conforms(to: .image), let data = try? Data(contentsOf: url) {
                return [imagePart(data)].compactMap { $0 }
            }
            if textExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .text) == true,
               let s = try? String(contentsOf: url, encoding: .utf8) {
                return [.text("[\(url.lastPathComponent)]\n" + String(s.prefix(200_000)))]
            }
            return [.text("[Ekli dosya: \(url.lastPathComponent) — içeriği okunamadı]")]
        }
    }

    /// API'ler PNG/JPEG/GIF/WebP kabul eder; diğer biçimler (HEIC, TIFF…) PNG'ye çevrilir, büyükler küçültülür.
    static func imagePart(_ data: Data) -> ChatPart? {
        if data.count < 4_000_000, let mime = sniff(data) { return .image(mime: mime, base64: data.base64EncodedString()) }
        guard let img = NSImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
        let s = img.size
        let scale = min(1, maxSide / max(s.width, s.height, 1))
        let target = NSSize(width: max(1, s.width * scale), height: max(1, s.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return .image(mime: "image/png", base64: png.base64EncodedString())
    }

    private static func sniff(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(12))
        guard b.count >= 4 else { return nil }
        if b[0] == 0x89, b[1] == 0x50 { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b[0] == 0x47, b[1] == 0x49 { return "image/gif" }
        if b.count >= 12, b[0] == 0x52, b[8] == 0x57, b[9] == 0x45 { return "image/webp" }
        return nil
    }
}

/// Akış olayları. Ayrıştırıcılar saf fonksiyonlar; --selftest ile örnek akışlarla sınanır.
enum StreamEvent: Equatable {
    case text(String)
    case error(String)
    case refusal
    case done
}

enum StreamParser {
    /// SSE satırından JSON gövdeyi alır ("data: {...}").
    static func sseData(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard body != "[DONE]", let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func anthropic(_ line: String) -> StreamEvent? {
        guard let j = sseData(line) else { return nil }
        switch j["type"] as? String {
        case "content_block_delta":
            let d = j["delta"] as? [String: Any]
            if d?["type"] as? String == "text_delta", let t = d?["text"] as? String { return .text(t) }
            return nil
        case "message_delta":
            let d = j["delta"] as? [String: Any]
            return d?["stop_reason"] as? String == "refusal" ? .refusal : nil
        case "message_stop":
            return .done
        case "error":
            return .error(((j["error"] as? [String: Any])?["message"] as? String) ?? "Bilinmeyen hata")
        default:
            return nil
        }
    }

    /// Anthropic akışındaki kullanım bilgisi: giriş message_start'ta, çıkış message_delta'da gelir.
    static func anthropicUsage(_ line: String) -> (input: Int, output: Int, cacheRead: Int, cacheWrite: Int)? {
        guard line.contains("usage"), let j = sseData(line) else { return nil }
        switch j["type"] as? String {
        case "message_start":
            guard let u = (j["message"] as? [String: Any])?["usage"] as? [String: Any] else { return nil }
            return (u["input_tokens"] as? Int ?? 0, 0, u["cache_read_input_tokens"] as? Int ?? 0, u["cache_creation_input_tokens"] as? Int ?? 0)
        case "message_delta":
            guard let u = j["usage"] as? [String: Any] else { return nil }
            return (0, u["output_tokens"] as? Int ?? 0, 0, 0)
        default:
            return nil
        }
    }

    /// OpenAI ve LM Studio (OpenAI uyumlu) chat/completions akışı.
    static func openai(_ line: String) -> StreamEvent? {
        if line.trimmingCharacters(in: .whitespaces) == "data: [DONE]" { return .done }
        guard let j = sseData(line) else { return nil }
        if let e = j["error"] as? [String: Any] { return .error(e["message"] as? String ?? "Bilinmeyen hata") }
        let choice = (j["choices"] as? [[String: Any]])?.first
        if let t = (choice?["delta"] as? [String: Any])?["content"] as? String, !t.isEmpty { return .text(t) }
        return nil
    }

    static func gemini(_ line: String) -> StreamEvent? {
        guard let j = sseData(line) else { return nil }
        if let e = j["error"] as? [String: Any] { return .error(e["message"] as? String ?? "Bilinmeyen hata") }
        let parts = (((j["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let t = parts.compactMap { $0["text"] as? String }.joined()
        return t.isEmpty ? nil : .text(t)
    }

    /// Ollama /api/chat: her satır ayrı bir JSON (NDJSON).
    static func ollama(_ line: String) -> StreamEvent? {
        guard let data = line.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let e = j["error"] as? String { return .error(e) }
        if let t = (j["message"] as? [String: Any])?["content"] as? String, !t.isEmpty { return .text(t) }
        return (j["done"] as? Bool) == true ? .done : nil
    }
}

/// Sağlayıcıya göre istek gövdesi kurar.
enum ChatRequestBuilder {
    struct BuildError: LocalizedError {
        let errorDescription: String?
    }

    static func request(provider: ChatProvider, model: String, system: String, messages: [ChatMessage]) throws -> URLRequest {
        let base = provider.baseURL
        var req: URLRequest
        var body: [String: Any]
        let key = provider.keychainKey.flatMap(Keychain.get)
        if !provider.isLocal, key == nil {
            throw BuildError(errorDescription: "\(provider.title) anahtarı yok. Ayarlar → Sohbet'ten ekle.")
        }

        switch provider {
        case .anthropic:
            req = URLRequest(url: URL(string: base + "/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // Güvenlik sınıflandırıcısı reddederse istek aynı çağrıda uygun modelle yeniden çalışır.
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body = ["model": model, "max_tokens": 16000, "stream": true, "system": system, "fallbacks": "default",
                    // Sistem istemi ve eski mesajlar önbellekten okunur.
                    "cache_control": ["type": "ephemeral"],
                    "messages": messages.map { m in ["role": m.role.rawValue, "content": anthropicContent(m)] }]
        case .openai, .lmstudio:
            req = URLRequest(url: URL(string: base + "/v1/chat/completions")!)
            if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            var msgs: [[String: Any]] = [["role": provider == .openai ? "developer" : "system", "content": system]]
            msgs += messages.map { m in ["role": m.role.rawValue, "content": openaiContent(m)] }
            body = ["model": model, "stream": true, "messages": msgs]
        case .gemini:
            let enc = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            req = URLRequest(url: URL(string: base + "/v1beta/models/\(enc):streamGenerateContent?alt=sse")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": messages.map { m in ["role": m.role == .user ? "user" : "model", "parts": geminiParts(m)] }]
        case .ollama:
            req = URLRequest(url: URL(string: base + "/api/chat")!)
            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            msgs += messages.map(ollamaMessage)
            body = ["model": model, "stream": true, "messages": msgs]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func parser(for p: ChatProvider) -> (String) -> StreamEvent? {
        switch p {
        case .anthropic: StreamParser.anthropic
        case .openai, .lmstudio: StreamParser.openai
        case .gemini: StreamParser.gemini
        case .ollama: StreamParser.ollama
        }
    }

    // MARK: - Biçimler

    static func anthropicContent(_ m: ChatMessage) -> Any {
        if m.parts.isEmpty { return m.text }
        var blocks: [[String: Any]] = []
        for p in m.parts {
            switch p {
            case .image(let mime, let b64):
                blocks.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": b64]])
            case .pdf(_, let b64, _):
                blocks.append(["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": b64]])
            case .text(let t):
                blocks.append(["type": "text", "text": t])
            }
        }
        if !m.text.isEmpty { blocks.append(["type": "text", "text": m.text]) }
        return blocks
    }

    static func openaiContent(_ m: ChatMessage) -> Any {
        if m.parts.isEmpty || m.role == .assistant { return m.text }
        var blocks: [[String: Any]] = []
        for p in m.parts {
            switch p {
            case .image(let mime, let b64):
                blocks.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(b64)"]])
            case .pdf(let name, _, let text):
                blocks.append(["type": "text", "text": "[\(name)]\n\(text)"])
            case .text(let t):
                blocks.append(["type": "text", "text": t])
            }
        }
        if !m.text.isEmpty { blocks.append(["type": "text", "text": m.text]) }
        return blocks
    }

    static func geminiParts(_ m: ChatMessage) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        for p in m.parts {
            switch p {
            case .image(let mime, let b64): parts.append(["inline_data": ["mime_type": mime, "data": b64]])
            case .pdf(_, let b64, _): parts.append(["inline_data": ["mime_type": "application/pdf", "data": b64]])
            case .text(let t): parts.append(["text": t])
            }
        }
        if !m.text.isEmpty || parts.isEmpty { parts.append(["text": m.text]) }
        return parts
    }

    static func ollamaMessage(_ m: ChatMessage) -> [String: Any] {
        var text = m.parts.compactMap { p -> String? in
            switch p {
            case .text(let t): t
            case .pdf(let name, _, let t): "[\(name)]\n\(t)"
            case .image: nil
            }
        }.joined(separator: "\n\n")
        text += (text.isEmpty ? "" : "\n\n") + m.text
        var out: [String: Any] = ["role": m.role.rawValue, "content": text]
        let images = m.parts.compactMap { p -> String? in if case .image(_, let b) = p { return b } else { return nil } }
        if !images.isEmpty { out["images"] = images }
        return out
    }
}
