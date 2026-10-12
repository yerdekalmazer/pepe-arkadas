import Foundation

/// Bir oturum bittiğinde proje md'sinin "Durum / Sıradaki / Kararlar" bölümlerini günceller.
/// Girdi sınırlı (~1-2 bin token): mevcut üç bölüm + bu oturumun kısa kaydı. Çıktı yapılandırılmış JSON —
/// model md'yi baştan yazmaz, yalnızca değişen alanları döner.
@MainActor enum MemorySummarizer {
    static func update(root: String, log: ProjectMemory.SessionLog, model: String) async {
        guard let key = Keychain.get("anthropic") else { return }
        var doc = ProjectDoc.load(root: root)
        let current = """
        Özet: \(doc.section("Özet").prefix(600))
        Durum: \(doc.section("Durum").prefix(500))
        Sıradaki: \(doc.section("Sıradaki").prefix(600))
        """
        let session = """
        İstekler: \(log.prompts.suffix(3).joined(separator: " | ").prefix(700))
        Değişen dosyalar: \(log.edited.prefix(15).joined(separator: ", "))
        Komutlar: \(log.commands.suffix(6).map { "\($0.0) \($0.1 ? "✓" : "✗")" }.joined(separator: "; ").prefix(500))
        Ajanın son mesajı: \(log.lastReply.prefix(900))
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "durum": ["type": "string", "description": "Projenin şu anki durumu, 1-2 cümle"],
                "siradaki": ["type": "array", "items": ["type": "string"], "description": "Açık kalan sonraki adımlar, en çok 5; biteni çıkar"],
                "kararlar": ["type": "array", "items": ["type": "string"], "description": "Bu oturumda alınan kalıcı kararlar; yoksa boş"],
            ],
            "required": ["durum", "siradaki", "kararlar"],
            "additionalProperties": false,
        ]
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": "Bir yazılım projesinin hafıza dosyasını güncelliyorsun. Türkçe, kısa ve somut yaz. Yalnızca verilen bilgiye dayan; tahmin etme.",
            "messages": [["role": "user", "content": "Mevcut hafıza:\n\(current)\n\nBu oturum:\n\(session)"]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
        ]
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        if !model.contains("haiku") {
            body["fallbacks"] = "default"
            r.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        r.httpBody = data
        guard let (respData, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] else { return }
        UsageMeter.shared.record(model: model, usage: json["usage"] as? [String: Any], purpose: .memory)
        guard (json["stop_reason"] as? String) != "refusal",
              let text = (json["content"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let out = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }

        // Dosya bu arada değişmiş olabilir: en güncelini oku, yalnızca üç bölüme dokun.
        doc = ProjectDoc.load(root: root)
        if let durum = out["durum"] as? String, !durum.isEmpty { doc.setSection("Durum", durum) }
        if let next = out["siradaki"] as? [String] {
            doc.setSection("Sıradaki", next.prefix(5).map { "- [ ] \($0)" }.joined(separator: "\n"))
        }
        if let decisions = out["kararlar"] as? [String], !decisions.isEmpty {
            let day = UsageMeter.dayKey(Date())
            var lines = doc.section("Kararlar").components(separatedBy: "\n").filter { !$0.isEmpty }
            lines.insert(contentsOf: decisions.map { "- \(day): \($0)" }, at: 0)
            doc.setSection("Kararlar", lines.prefix(25).joined(separator: "\n"))
        }
        doc.save()
    }
}
