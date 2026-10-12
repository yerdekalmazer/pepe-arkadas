import Foundation

/// Oturuma yazarken `/` ile başlayan komut önerileri — terminaldeki gibi. `claude -p` da bu komutları çalıştırır
/// (/compact, /context, /usage, beceriler, özel komutlar…). Liste Claude Code'un her çalıştırmada bildirdiği
/// `slash_commands`'tan gelir; hiç çalıştırılmadıysa yaygın komutlar ve diskteki beceriler gösterilir.
@MainActor enum SlashCommands {
    private static let key = "slashKomutlari"

    /// Bilinen komutların kısa açıklaması.
    static let hints: [String: String] = [
        "compact": "Konuşmayı özetleyip bağlamı boşalt",
        "context": "Bağlamın ne kadarı dolu",
        "usage": "Plan kullanımı ve sıfırlanma saatleri",
        "cost": "Bu oturumun maliyeti",
        "init": "Proje için CLAUDE.md oluştur",
        "review": "Değişiklikleri gözden geçir",
        "code-review": "Değişiklikleri gözden geçir",
        "security-review": "Güvenlik incelemesi",
        "simplify": "Değişen kodu sadeleştir",
        "recap": "Oturumun özeti",
        "insights": "Oturum içgörüleri",
        "model": "Modeli değiştir (ör. /model opus)",
        "effort": "Efor düzeyini değiştir (ör. /effort high)",
        "rename": "Oturuma ad ver",
        "mcp": "MCP sunucularının durumu",
        "agents": "Alt ajanlar",
        "doctor": "Kurulumu denetle",
        "debug": "Hata ayıklama",
        "goal": "Oturuma hedef koy",
        "loop": "Bir komutu aralıklarla çalıştır",
        "schedule": "Zamanlanmış görev",
        "clear": "Konuşmayı sıfırla (yeni oturum başlar)",
    ]

    /// Arka planda anlamı olmayanlar listelenmez.
    private static let hidden: Set<String> = ["heapdump", "workflow-launch-exec", "color", "focus", "fast",
                                              "design-consent", "design-revoke", "reload-plugins", "reload-skills"]

    private static let common = ["compact", "context", "usage", "cost", "init", "review", "security-review", "recap",
                                 "model", "effort", "rename", "mcp", "agents", "doctor", "clear"]

    /// Claude Code'un son bildirdiği liste.
    static var known: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Çalıştırma çıktısındaki init satırından listeyi kaydeder.
    static func record(from output: Data) {
        for line in output.split(separator: 0x0A).prefix(40) {
            guard line.count > 2, let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  d["type"] as? String == "system", d["subtype"] as? String == "init",
                  let list = d["slash_commands"] as? [String], !list.isEmpty else { continue }
            known = list
            return
        }
    }

    /// Projedeki ve kullanıcıdaki beceri/komut dosyaları (liste henüz gelmediyse ya da projeye özgüyse).
    private static func onDisk(_ cwd: String) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var names: [String] = []
        for base in ["\(home)/.claude", "\(cwd)/.claude"] {
            names += ((try? fm.contentsOfDirectory(atPath: base + "/skills")) ?? []).filter { !$0.hasPrefix(".") }
            names += ((try? fm.contentsOfDirectory(atPath: base + "/commands")) ?? [])
                .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }
        }
        return names
    }

    /// `/` ile başlayan ve henüz boşluk içermeyen yazıya uyan komutlar: önce baştan eşleşenler.
    static func suggestions(for text: String, cwd: String, limit: Int = 6) -> [(name: String, hint: String)] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let q = text.dropFirst().lowercased()
        var seen = Set<String>()
        let all = (common + known + onDisk(cwd)).filter { n in
            !n.hasPrefix("__") && !n.hasPrefix("mcp__") && !hidden.contains(n) && seen.insert(n).inserted
        }
        let starts = all.filter { $0.lowercased().hasPrefix(q) }
        let contains = q.isEmpty ? [] : all.filter { !$0.lowercased().hasPrefix(q) && $0.lowercased().contains(q) }
        let picked = (starts + contains).prefix(limit)
        if picked.count == 1, picked.first?.lowercased() == q { return [] }
        return picked.map { ($0, hints[$0] ?? "") }
    }
}
