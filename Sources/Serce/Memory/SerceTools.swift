import Foundation

/// Sohbet ve sesli asistanın ortak yerel araçları: proje hafızasını okuma/arama, oturumlara yazma.
/// Hepsi bu Mac'te çalışır; modele yalnızca kısa sonuçları döner.
@MainActor enum SerceTools {
    static let names: Set<String> = ["project_memory", "search_memory", "send_to_session", "start_session", "set_reminder",
                                     "list_reminders", "cancel_reminder", "set_automation", "list_automations",
                                     "cancel_automation", "briefing", "trello_cards", "trello_add_card", "trello_move_card"]

    static func owns(_ name: String) -> Bool { names.contains(name) }

    static var definitions: [[String: Any]] {
        [
            tool("project_memory", "Bir projenin hafıza dosyasını (özet, durum, sıradaki adımlar, kararlar, son oturumlar) okur.",
                 ["project": ["type": "string", "description": "Proje adı"]], required: ["project"]),
            tool("search_memory", "Tüm proje hafızalarında kelime araması yapar (ör. 'supabase pooler').",
                 ["query": ["type": "string"]], required: ["query"]),
            tool("read_session", "Bir ajan oturumunun durumunu, görevini, son yanıtını ve hata veren adımını okur. Bir oturumdaki sorunu başka bir ajana aktarmadan önce kullan.",
                 ["project": ["type": "string", "description": "Oturumun proje adı; boşsa en son oturum"],
                  "agent": ["type": "string", "description": "claude, codex, gemini, cursor… (isteğe bağlı)"]],
                 required: []),
            tool("send_to_session", "Var olan bir Claude Code, Codex ya da Gemini CLI oturumuna mesaj gönderir; terminal açık olmasa da arka planda devam eder. Oturum çalışıyorsa mesaj sıraya girer, bitince gider. Başka bir oturumdan aktarırken read_session ile okuduğun hatayı/yanıtı mesaja koy.",
                 ["project": ["type": "string", "description": "Oturumun proje adı; boşsa en son oturum"],
                  "agent": ["type": "string", "enum": ["claude", "codex", "gemini"], "description": "Hedef ajan (isteğe bağlı)"],
                  "message": ["type": "string", "description": "Ajana gönderilecek talimat, kullanıcının ağzından"]],
                 required: ["message"]),
            tool("start_session", "Bir projenin klasöründe yeni bir ajan oturumu (varsayılan Claude Code; Codex ya da Gemini CLI da olur) başlatır ve görevi verir.",
                 ["project": ["type": "string", "description": "Hafızadaki proje adı"],
                  "message": ["type": "string", "description": "Görev"],
                  "agent": ["type": "string", "enum": ["claude", "codex", "gemini"], "description": "Hangi ajan; kullanıcı belirtmediyse claude"],
                  "worktree": ["type": "boolean", "description": "Ayrı git çalışma kopyasında aç (projede başka oturum çalışıyorsa önerilir)"]],
                 required: ["project", "message"]),
            tool("set_reminder", "Hatırlatma kurar. Zamanı ya 'at' (yerel saat, 'YYYY-MM-DD HH:mm') ya da 'in_minutes' ile ver.",
                 ["text": ["type": "string"], "at": ["type": "string"], "in_minutes": ["type": "integer"],
                  "project": ["type": "string", "description": "İlgili proje (isteğe bağlı)"]], required: ["text"]),
            tool("list_reminders", "Bekleyen hatırlatmaları listeler.", [:], required: []),
            tool("cancel_reminder", "Metni eşleşen bekleyen hatırlatmaları iptal eder.",
                 ["query": ["type": "string"]], required: ["query"]),
            tool("set_automation", "Tekrarlayan otomasyon kurar: her gün (ya da seçili günlerde) belirlenen saatte 'message' sohbete gönderilir ve sen cevaplarsın. Tek seferlik iş için set_reminder kullan.",
                 ["message": ["type": "string", "description": "O saatte sohbete gidecek mesaj, kullanıcının ağzından (ör. 'Bugünün planını çıkar')"],
                  "time": ["type": "string", "description": "Yerel saat, 'HH:mm'"],
                  "days": ["description": "'everyday' (varsayılan), 'weekdays', 'weekends' ya da gün numaraları dizisi (1 = pazartesi … 7 = pazar)"]],
                 required: ["message", "time"]),
            tool("list_automations", "Kurulu otomasyonları listeler.", [:], required: []),
            tool("cancel_automation", "Mesajı eşleşen otomasyonları siler.",
                 ["query": ["type": "string"]], required: ["query"]),
            tool("briefing", "Günün brifingini verir: dün çalışılan projeler, kalınan yerler, hatırlatmalar, Trello/GitHub/takvim.",
                 ["weekly": ["type": "boolean", "description": "Geçen haftanın özetini de ekle"]], required: []),
            tool("trello_cards", "Trello'da bir listedeki kartları okur (varsayılan: Kişisel Alan panosu).",
                 ["board": ["type": "string"], "list": ["type": "string", "description": "ör. Bugün, Bu Hafta, Gelen Kutusu"]],
                 required: ["list"]),
            tool("trello_add_card", "Trello'ya kart ekler. Yalnızca Kişisel Alan ve VizeX panolarına yazılabilir; kullanıcı notch'ta onaylar.",
                 ["board": ["type": "string", "description": "Varsayılan Kişisel Alan"], "list": ["type": "string"],
                  "title": ["type": "string"], "description": ["type": "string"]], required: ["list", "title"]),
            tool("trello_move_card", "Bir kartı başka listeye taşır (ör. Bitti'ye). Yalnızca Kişisel Alan ve VizeX; kullanıcı onaylar.",
                 ["board": ["type": "string"], "card": ["type": "string", "description": "Kart adından bir parça"],
                  "to_list": ["type": "string"]], required: ["card", "to_list"]),
        ]
    }

    /// Sistem istemine eklenen kısa not: yalnızca proje adları (içerik araçla okunur).
    /// Sistem istemine eklenen kısa not: bugünün tarihi (gün değişince değişir; önbellek gün boyu geçerli),
    /// "ben" dosyası ve yalnızca proje adları (içerik araçla okunur).
    static func systemNote() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMMM yyyy EEEE"
        var note = "\nBugün: \(f.string(from: Date())) (saat dilimi \(TimeZone.current.identifier)). Saat gerekiyorsa get_status ya da hatırlatmada in_minutes kullan."
        note += AboutMe.promptBlock()
        let names = ProjectMemory.allDocs().map(\.name).prefix(60)
        if !names.isEmpty {
            note += "\nProje hafızası olan projeler: \(names.joined(separator: ", ")). Ayrıntı gerekirse project_memory ya da search_memory kullan."
        }
        return note
    }

    static func progress(_ name: String) -> String {
        switch name {
        case "project_memory", "search_memory": "Proje hafızası"
        case "read_session": "Oturum okunuyor"
        default: "Oturuma yazılıyor"
        }
    }

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": desc, "input_schema": ["type": "object", "properties": props, "required": required] as [String: Any]]
    }

    static func run(_ name: String, _ input: [String: Any]) async -> (String, Bool) {
        let store = AppState.shared.store
        switch name {
        case "project_memory":
            guard let doc = ProjectMemory.find(input["project"] as? String ?? "") else { return ("Bu adla proje hafızası yok.", true) }
            let text = doc.text
            return (text.count > 6000 ? String(text.prefix(6000)) + "\n…(kısaltıldı)" : text, false)

        case "search_memory":
            let hits = ProjectMemory.search(input["query"] as? String ?? "")
            return (hits.isEmpty ? "Eşleşme yok." : hits.joined(separator: "\n"), false)

        case "read_session":
            let q = (input["project"] as? String ?? "").lowercased()
            let agent = (input["agent"] as? String ?? "").lowercased()
            guard let s = store.sessions.filter({ (q.isEmpty || $0.project.lowercased().contains(q)) && (agent.isEmpty || $0.agent == agent) })
                .max(by: { $0.updated < $1.updated }) else { return ("Böyle bir oturum yok.", true) }
            var out = ["\(s.project) · \(s.agentName) · durum: \(s.action)", "Klasör: \(s.cwd)"]
            if !s.prompt.isEmpty { out.append("Görev: " + String(s.prompt.prefix(1500))) }
            if let f = Forward.failedStep(in: s) { out.append("Hata veren adım:\n" + String(Forward.text(of: f).prefix(3000))) }
            if !s.lastReply.isEmpty { out.append("Son yanıt:\n" + String(s.lastReply.prefix(3000))) }
            return (out.joined(separator: "\n\n"), false)

        case "send_to_session":
            let q = (input["project"] as? String ?? "").lowercased()
            let message = input["message"] as? String ?? ""
            let agent = (input["agent"] as? String ?? "").lowercased()
            let candidates = store.sessions.filter { AgentRunner.canWrite($0.agent) && (agent.isEmpty || $0.agent == agent) }
            // Aynı projede birden fazla oturum varsa: çalışmayan, en son güncellenen.
            let matching = candidates.filter { q.isEmpty || $0.project.lowercased().contains(q) }
                .sorted { $0.updated > $1.updated }
            guard let s = matching.first(where: { $0.status != .working }) ?? matching.first else {
                return ("Açık ya da yakın zamanda çalışmış bir Claude Code, Codex ya da Gemini oturumu bulunamadı; start_session kullanılabilir.", true)
            }
            let busy = s.status == .working || AgentRunner.shared.isRunning(s.id)
            if let err = ComposerStore.shared.enqueue(message, for: s) { return (err, true) }
            return (busy ? "\(s.project) (\(s.agentName)) çalışıyor; mesaj sıraya alındı, bitince gidecek."
                         : "\(s.project) (\(s.agentName)) oturumuna gönderildi; ilerleme notch'ta görünecek.", false)

        case "start_session":
            guard let doc = ProjectMemory.find(input["project"] as? String ?? ""), !doc.root.isEmpty else {
                return ("Bu proje hafızada yok ya da klasörü bilinmiyor.", true)
            }
            let wt = input["worktree"] as? Bool ?? AgentRunner.shared.hasActiveSession(in: doc.root)
            let agent = RunnableAgent(agent: input["agent"] as? String ?? "") ?? .claude
            if let err = AgentRunner.shared.start(input["message"] as? String ?? "", in: doc.root, worktree: wt, agent: agent) { return (err, true) }
            return ("\(doc.name) projesinde yeni \(agent.title) oturumu başladı\(wt ? " (ayrı çalışma kopyasında)" : "").", false)

        case "set_reminder":
            let text = input["text"] as? String ?? ""
            let when: Date? = (input["in_minutes"] as? Int).map { Date().addingTimeInterval(Double($0) * 60) }
                ?? (input["at"] as? String).flatMap(Reminders.parse)
            guard !text.isEmpty, let when else { return ("Zaman anlaşılmadı; 'at' ya da 'in_minutes' ver.", true) }
            guard when > Date() else { return ("Bu zaman geçmişte kalıyor.", true) }
            Reminders.shared.add(text, at: when, project: input["project"] as? String)
            return ("Kuruldu: \(Reminders.format(when)) — \(text)", false)

        case "list_reminders":
            let items = Reminders.shared.upcoming
            return (items.isEmpty ? "Bekleyen hatırlatma yok." : items.map { "\(Reminders.format($0.at)): \($0.text)" }.joined(separator: "\n"), false)

        case "cancel_reminder":
            let n = Reminders.shared.cancel(matching: input["query"] as? String ?? "")
            return (n == 0 ? "Eşleşen hatırlatma yok." : "\(n) hatırlatma iptal edildi.", n == 0)

        case "set_automation":
            let message = input["message"] as? String ?? ""
            guard !message.isEmpty, let minute = Automations.parseTime(input["time"] as? String ?? "") else {
                return ("Mesaj ya da saat anlaşılmadı; 'time' 'HH:mm' olmalı.", true)
            }
            let item = Automations.shared.add(message, minute: minute, days: Automations.parseDays(input["days"]))
            return ("Kuruldu: \(Automations.daysLabel(item.days)) \(Automations.time(item.minute)) · \(message)", false)

        case "list_automations":
            let items = Automations.shared.items
            return (items.isEmpty ? "Kurulu otomasyon yok." : items.map {
                "\(Automations.daysLabel($0.days)) \(Automations.time($0.minute))\($0.enabled ? "" : " (kapalı)"): \($0.message)"
            }.joined(separator: "\n"), false)

        case "cancel_automation":
            let n = Automations.shared.cancel(matching: input["query"] as? String ?? "")
            return (n == 0 ? "Eşleşen otomasyon yok." : "\(n) otomasyon silindi.", n == 0)

        case "briefing":
            return (Briefing.shared.text(weekly: input["weekly"] as? Bool ?? false), false)

        case "trello_cards":
            do {
                let (b, l) = try await TrelloAPI.resolve(board: input["board"] as? String, list: input["list"] as? String ?? "Inbox")
                guard let l else { return ("Liste bulunamadı.", true) }
                let cards = try await TrelloAPI.cards(list: l)
                return (cards.isEmpty ? "\(b.name) › \(l.name) boş." :
                        "\(b.name) › \(l.name):\n" + cards.prefix(30).map { "- \($0.name)" }.joined(separator: "\n"), false)
            } catch { return (error.localizedDescription, true) }

        case "trello_add_card", "trello_move_card":
            let board = input["board"] as? String
            if let board, !TrelloAPI.isWritable(board) { return (TrelloAPI.Failure.forbidden(board).localizedDescription, true) }
            let add = name == "trello_add_card"
            let decision = await store.requestLocalApproval(
                project: "Trello", tool: add ? "Trello · kart ekle" : "Trello · kart taşı",
                title: add ? "Trello'ya kart eklemek istiyor" : "Trello'da kart taşımak istiyor", input: input, allowAlways: false)
            guard decision == .allow || decision == .always else { return ("Kullanıcı reddetti.", true) }
            do {
                let r = add
                    ? try await TrelloAPI.addCard(board: board, list: input["list"] as? String ?? "", name: input["title"] as? String ?? "",
                                                  desc: input["description"] as? String ?? "")
                    : try await TrelloAPI.moveCard(board: board, card: input["card"] as? String ?? "", toList: input["to_list"] as? String ?? "")
                return (r, false)
            } catch { return (error.localizedDescription, true) }

        default:
            return ("Bilinmeyen araç.", true)
        }
    }
}
