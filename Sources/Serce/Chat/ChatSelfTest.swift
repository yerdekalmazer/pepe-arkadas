import Foundation

/// Gerçek anahtar olmadan sınanabilen kısımlar: akış ayrıştırıcıları ve istek gövdeleri.
enum ChatSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ got: [StreamEvent], _ want: [StreamEvent]) {
            if got != want { failures.append("\(name): beklenen \(want), gelen \(got)") }
        }
        func feed(_ text: String, _ parse: (String) -> StreamEvent?) -> [StreamEvent] {
            text.components(separatedBy: "\n").compactMap(parse)
        }

        let anthropic = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Merhaba"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" dünya"}}

        event: ping
        data: {"type": "ping"}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        event: message_stop
        data: {"type":"message_stop"}
        """
        expect("anthropic", feed(anthropic, StreamParser.anthropic), [.text("Merhaba"), .text(" dünya"), .done])
        expect("anthropic-ret", feed(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#, StreamParser.anthropic), [.refusal])
        expect("anthropic-hata", feed(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, StreamParser.anthropic), [.error("Overloaded")])

        let openai = """
        data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}

        data: {"id":"c1","choices":[{"index":0,"delta":{"content":"Selam"}}]}

        data: {"id":"c1","choices":[{"index":0,"delta":{"content":"!"},"finish_reason":null}]}

        data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]
        """
        expect("openai", feed(openai, StreamParser.openai), [.text("Selam"), .text("!"), .done])

        let gemini = """
        data: {"candidates":[{"content":{"parts":[{"text":"Bir"}],"role":"model"}}]}

        data: {"candidates":[{"content":{"parts":[{"text":" iki"}],"role":"model"},"finishReason":"STOP"}]}
        """
        expect("gemini", feed(gemini, StreamParser.gemini), [.text("Bir"), .text(" iki")])

        let ollama = """
        {"model":"llama3","message":{"role":"assistant","content":"Hey"},"done":false}
        {"model":"llama3","message":{"role":"assistant","content":" sen"},"done":false}
        {"model":"llama3","message":{"role":"assistant","content":""},"done":true}
        """
        expect("ollama", feed(ollama, StreamParser.ollama), [.text("Hey"), .text(" sen"), .done])

        // İstek gövdeleri: görsel + PDF blokları doğru biçimde mi?
        var m = ChatMessage(role: .user, text: "Bak")
        m.parts = [.image(mime: "image/png", base64: "AAA"), .pdf(name: "a.pdf", base64: "BBB", text: "pdf metni")]
        let a = ChatRequestBuilder.anthropicContent(m) as? [[String: Any]] ?? []
        if a.map({ $0["type"] as? String ?? "" }) != ["image", "document", "text"] { failures.append("anthropic içerik: \(a)") }
        let o = ChatRequestBuilder.openaiContent(m) as? [[String: Any]] ?? []
        if o.map({ $0["type"] as? String ?? "" }) != ["image_url", "text", "text"] { failures.append("openai içerik: \(o)") }
        let g = ChatRequestBuilder.geminiParts(m)
        if g.count != 3 || g[0]["inline_data"] == nil { failures.append("gemini parçaları: \(g)") }
        let ol = ChatRequestBuilder.ollamaMessage(m)
        if (ol["images"] as? [String]) != ["AAA"] || !(ol["content"] as? String ?? "").contains("pdf metni") { failures.append("ollama: \(ol)") }

        if failures.isEmpty {
            print("sohbet selftest: tamam (6 akış, 4 gövde)")
            return true
        }
        failures.forEach { print("HATA \($0)") }
        return false
    }
}
