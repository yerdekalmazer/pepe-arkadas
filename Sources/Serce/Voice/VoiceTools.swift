import AppKit
import Contacts

/// Diğer özellik gruplarının sesli asistana açtığı kancalar. Features.register içinde doldurulur.
@MainActor enum VoiceHooks {
    /// Müzik: eylem ("play", "pause", "resume", "next", "previous", "volume"), arama, seviye (0-100) → sonuç cümlesi.
    static var music: ((String, String?, Int?) async -> String)?
    /// E-posta taslağı aç (gönderme yok).
    static var composeMail: ((_ to: [String], _ subject: String, _ body: String) -> Void)?
}

/// Sesli asistanın araçları: tanımlar (JSON şema) ve yürütücüler.
@MainActor enum VoiceTools {
    static var definitions: [[String: Any]] {
        [
            tool("get_status", "Şu anki durum: tarih/saat, ajan oturumları (proje, ajan, durum, son adım), bekleyen izinler, aktif pill'ler, çalan müzik.", [:]),
            tool("read_pill", "Bir pill'in güncel verisini okur (Stripe cirosu, GitHub PR'ları, Vercel deploy'ları vb.).",
                 ["id": ["type": "string", "description": "Pill kimliği; list_pills'ten."]], required: ["id"]),
            tool("list_pills", "Kullanılabilir tüm pill'leri ve hangilerinin notch'ta açık olduğunu listeler.", [:]),
            tool("set_pills", "Notch'taki pill'leri değiştirir: ekle, kaldır ya da birini diğeriyle değiştir.",
                 ["add": ["type": "array", "items": ["type": "string"], "description": "Açılacak pill kimlikleri"],
                  "remove": ["type": "array", "items": ["type": "string"], "description": "Kapatılacak pill kimlikleri"],
                  "swap_old": ["type": "string", "description": "Yerine başkası konacak pill"],
                  "swap_new": ["type": "string", "description": "swap_old'un yerine gelecek pill"]]),
            tool("music", "Müzik çalar (Spotify ya da Apple Music): bir şey çal, duraklat, devam, sonraki, önceki, ses seviyesi.",
                 ["action": ["type": "string", "enum": ["play", "pause", "resume", "next", "previous", "volume"]],
                  "query": ["type": "string", "description": "play için sanatçı/şarkı/albüm"],
                  "level": ["type": "integer", "description": "volume için 0-100"]], required: ["action"]),
            tool("compose_email", "Bir kişiye e-posta taslağı açar (rehberde adını arar). Gönderme kullanıcıdadır.",
                 ["to": ["type": "string", "description": "Kişinin adı ya da e-posta adresi"],
                  "subject": ["type": "string"], "body": ["type": "string", "description": "Kısa, kullanıcının ağzından e-posta metni"]],
                 required: ["to", "body"]),
            tool("open_app", "Mac'te bir uygulamayı açar ya da öne getirir.",
                 ["name": ["type": "string", "description": "Uygulamanın adı, ör. Safari, Figma"]], required: ["name"]),
            tool("answer_permission", "Bekleyen ilk ajan izin isteğini yanıtlar.",
                 ["decision": ["type": "string", "enum": ["allow", "deny"]]], required: ["decision"]),
            tool("open_terminal", "Bir ajan oturumunun terminaline gider.",
                 ["project": ["type": "string", "description": "Proje adı; boşsa en son oturum"]]),
        ]
    }

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc,
         "input_schema": ["type": "object", "properties": props, "required": required] as [String: Any]]
    }

    static func run(_ name: String, _ input: [String: Any]) async -> (String, Bool) {
        let app = AppState.shared
        switch name {
        case "get_status":
            return (status(app), false)

        case "list_pills":
            let lines = app.pills.all.map { p in
                "\(p.id): \(p.title)\(app.pills.isActive(p.id) ? " (açık)" : "")\(p.isConfigured ? "" : " (kurulum gerekli)")"
            }
            return (lines.isEmpty ? "Hiç pill yok." : lines.joined(separator: "\n"), false)

        case "read_pill":
            let id = input["id"] as? String ?? ""
            guard let p = app.pills.provider(id) else { return ("'\(id)' adında pill yok.", true) }
            guard p.isConfigured else { return ("\(p.title) kurulmamış; Ayarlar'dan anahtar eklenmeli.", true) }
            let s = p.voiceSummary
            return (s.isEmpty ? "\(p.title) için okunabilir veri yok." : s, false)

        case "set_pills":
            var done: [String] = []
            if let old = input["swap_old"] as? String, let new = input["swap_new"] as? String {
                guard app.pills.provider(new) != nil else { return ("'\(new)' adında pill yok.", true) }
                app.pills.swap(old, with: new)
                done.append("\(old) yerine \(new)")
            }
            for id in input["add"] as? [String] ?? [] where app.pills.provider(id) != nil {
                app.pills.setActive(id, true); done.append("+\(id)")
            }
            for id in input["remove"] as? [String] ?? [] {
                app.pills.setActive(id, false); done.append("-\(id)")
            }
            return (done.isEmpty ? "Değişiklik yapılmadı." : "Yapıldı: " + done.joined(separator: ", "), done.isEmpty)

        case "music":
            guard let music = VoiceHooks.music else { return ("Müzik kontrolü bu sürümde yok.", true) }
            return (await music(input["action"] as? String ?? "", input["query"] as? String, input["level"] as? Int), false)

        case "compose_email":
            let to = input["to"] as? String ?? ""
            guard let address = await resolveEmail(to) else {
                return ("'\(to)' için rehberde e-posta adresi bulunamadı (ya da rehber izni yok).", true)
            }
            let subject = input["subject"] as? String ?? ""
            let body = input["body"] as? String ?? ""
            if let compose = VoiceHooks.composeMail {
                compose([address], subject, body)
            } else {
                var c = URLComponents()
                c.scheme = "mailto"
                c.path = address
                c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
                if let url = c.url { NSWorkspace.shared.open(url) }
            }
            return ("\(address) adresine taslak açıldı; gönderilmedi.", false)

        case "open_app":
            let name = input["name"] as? String ?? ""
            guard let url = findApp(name) else { return ("'\(name)' adında uygulama bulunamadı.", true) }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            return ("\(url.deletingPathExtension().lastPathComponent) açıldı.", false)

        case "answer_permission":
            guard let a = app.store.approvals.first else { return ("Bekleyen izin isteği yok.", true) }
            let allow = (input["decision"] as? String) == "allow"
            app.store.decide(a, allow ? .allow : .deny)
            return ("\(a.project): \(a.tool) \(allow ? "izni verildi" : "reddedildi").", false)

        case "open_terminal":
            let q = (input["project"] as? String ?? "").lowercased()
            let s = q.isEmpty ? app.store.sessions.first
                : app.store.sessions.first { $0.project.lowercased().contains(q) }
            guard let s else { return ("Böyle bir oturum yok.", true) }
            app.actions.openTerminal(s)
            return ("\(s.project) terminali öne getirildi.", false)

        default:
            return ("Bilinmeyen araç: \(name)", true)
        }
    }

    private static func status(_ app: AppState) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMMM yyyy EEEE, HH:mm"
        var lines = ["Şimdi: \(f.string(from: Date()))"]
        if app.store.sessions.isEmpty {
            lines.append("Ajan oturumu yok.")
        }
        for s in app.store.sessions.prefix(6) {
            let state: String
            switch s.status {
            case .working: state = "çalışıyor"
            case .waiting: state = "izin/yanıt bekliyor"
            case .done: state = "bitti"
            case .idle: state = "boşta"
            }
            lines.append("Oturum \(s.project): \(state); son: \(s.action)\(s.prompt.isEmpty ? "" : "; istek: \(s.prompt.prefix(120))")")
        }
        for a in app.store.approvals {
            lines.append("Bekleyen izin: \(a.project) \(a.tool) — \(a.detail.prefix(160))")
        }
        let active = app.pills.active.map(\.title)
        lines.append(active.isEmpty ? "Açık pill yok." : "Açık pill'ler: " + active.joined(separator: ", "))
        if app.musicPlaying { lines.append("Müzik çalıyor.") }
        return lines.joined(separator: "\n")
    }

    private static func findApp(_ name: String) -> URL? {
        let fm = FileManager.default
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var partial: URL?
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                let base = (item as NSString).deletingPathExtension.lowercased()
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                if base == wanted { return url }
                if partial == nil, base.contains(wanted) { partial = url }
            }
        }
        return partial
    }

    /// Ad ya da adres → e-posta. Rehber izni yoksa ister; reddedilirse nil.
    private static func resolveEmail(_ who: String) async -> String? {
        let trimmed = who.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return trimmed }
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { return nil }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: trimmed)
        let found = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        return found.lazy.compactMap { $0.emailAddresses.first?.value as String? }.first
    }
}
