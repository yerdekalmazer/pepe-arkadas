import Foundation

/// "Ben" dosyası: Hafiza/_ben.md — kim olduğun, tercihlerin, kuralların. Sohbet ve ses sistem istemine
/// en fazla ~1500 karakter girer (önbellekten okunduğu için her turda tam maliyet ödenmez).
/// İlk açılışta Claude hafızasındaki user_* ve feedback_* notlarının başlıklarından LLM'siz tohumlanır.
enum AboutMe {
    static var url: URL { ProjectMemory.dir.appendingPathComponent("_ben.md") }

    static func text() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Sistem istemine giden kısa hali: frontmatter ve başlıklar atılır, kırpılır.
    static func promptBlock() -> String {
        let body = text().components(separatedBy: "\n")
            .filter { !$0.hasPrefix("---") && !$0.hasPrefix("kaynak:") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { !$0.hasPrefix("_") }
            .joined(separator: "\n")
        guard !body.isEmpty else { return "" }
        return "\nKullanıcı hakkında (kendi notları):\n" + String(body.prefix(1500))
    }

    static func seedIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var about: [String] = [], rules: [String] = []
        for proj in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            let mem = base.appendingPathComponent(proj).appendingPathComponent("memory")
            for file in ((try? fm.contentsOfDirectory(atPath: mem.path)) ?? []).sorted() {
                guard file.hasPrefix("user") || file.hasPrefix("feedback"),
                      let s = try? String(contentsOf: mem.appendingPathComponent(file), encoding: .utf8),
                      let r = s.range(of: "description:") else { continue }
                let desc = String(s[r.upperBound...].prefix { $0 != "\n" }).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    .replacingOccurrences(of: "\\\"", with: "\"")
                guard !desc.isEmpty else { continue }
                if file.hasPrefix("user") { about.append("- " + desc) } else { rules.append("- " + desc) }
            }
        }
        let doc = """
        ---
        kaynak: Serçe
        ---
        # Ben

        _Serçe ve sohbet/ses bu dosyayı okur. Kısa tut: her satır her konuşmaya girer._

        ## Hakkımda
        \(about.prefix(10).joined(separator: "\n"))

        ## Kurallarım
        \(rules.prefix(20).joined(separator: "\n"))

        ## Tercihler
        - Türkçe konuş, kısa ve net ol.

        """
        try? fm.createDirectory(at: ProjectMemory.dir, withIntermediateDirectories: true)
        try? doc.write(to: url, atomically: true, encoding: .utf8)
    }
}
