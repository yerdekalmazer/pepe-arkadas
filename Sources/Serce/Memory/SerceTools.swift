import Foundation

/// Sohbet ve sesli asistanın ortak yerel araçları: proje hafızasını okuma/arama, oturumlara yazma.
/// Hepsi bu Mac'te çalışır; modele yalnızca kısa sonuçları döner.
@MainActor enum SerceTools {
    static let names: Set<String> = ["project_memory", "search_memory", "send_to_session", "start_session"]

    static func owns(_ name: String) -> Bool { names.contains(name) }

    static var definitions: [[String: Any]] {
        [
            tool("project_memory", "Bir projenin hafıza dosyasını (özet, durum, sıradaki adımlar, kararlar, son oturumlar) okur.",
                 ["project": ["type": "string", "description": "Proje adı"]], required: ["project"]),
            tool("search_memory", "Tüm proje hafızalarında kelime araması yapar (ör. 'supabase pooler').",
                 ["query": ["type": "string"]], required: ["query"]),
            tool("send_to_session", "Var olan bir Claude Code oturumuna mesaj gönderir; terminal açık olmasa da arka planda devam eder.",
                 ["project": ["type": "string", "description": "Oturumun proje adı; boşsa en son oturum"],
                  "message": ["type": "string", "description": "Ajana gönderilecek talimat, kullanıcının ağzından"]],
                 required: ["message"]),
            tool("start_session", "Bir projenin klasöründe yeni bir Claude Code oturumu başlatır ve görevi verir.",
                 ["project": ["type": "string", "description": "Hafızadaki proje adı"],
                  "message": ["type": "string", "description": "Görev"]],
                 required: ["project", "message"]),
        ]
    }

    /// Sistem istemine eklenen kısa not: yalnızca proje adları (içerik araçla okunur).
    static func systemNote() -> String {
        let names = ProjectMemory.allDocs().map(\.name).prefix(60)
        guard !names.isEmpty else { return "" }
        return "\nProje hafızası olan projeler: \(names.joined(separator: ", ")). Ayrıntı gerekirse project_memory ya da search_memory kullan."
    }

    static func progress(_ name: String) -> String {
        switch name {
        case "project_memory", "search_memory": "Proje hafızası"
        default: "Oturuma yazılıyor"
        }
    }

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": desc, "input_schema": ["type": "object", "properties": props, "required": required] as [String: Any]]
    }

    static func run(_ name: String, _ input: [String: Any]) -> (String, Bool) {
        let store = AppState.shared.store
        switch name {
        case "project_memory":
            guard let doc = ProjectMemory.find(input["project"] as? String ?? "") else { return ("Bu adla proje hafızası yok.", true) }
            let text = doc.text
            return (text.count > 6000 ? String(text.prefix(6000)) + "\n…(kısaltıldı)" : text, false)

        case "search_memory":
            let hits = ProjectMemory.search(input["query"] as? String ?? "")
            return (hits.isEmpty ? "Eşleşme yok." : hits.joined(separator: "\n"), false)

        case "send_to_session":
            let q = (input["project"] as? String ?? "").lowercased()
            let message = input["message"] as? String ?? ""
            let candidates = store.sessions.filter { $0.agent == AgentCatalog.claude }
            guard let s = q.isEmpty ? candidates.first : candidates.first(where: { $0.project.lowercased().contains(q) }) else {
                return ("Açık ya da yakın zamanda çalışmış bir Claude Code oturumu bulunamadı; start_session kullanılabilir.", true)
            }
            if let err = AgentRunner.shared.send(message, to: s) { return (err, true) }
            return ("\(s.project) oturumuna gönderildi; ilerleme notch'ta görünecek.", false)

        case "start_session":
            guard let doc = ProjectMemory.find(input["project"] as? String ?? ""), !doc.root.isEmpty else {
                return ("Bu proje hafızada yok ya da klasörü bilinmiyor.", true)
            }
            if let err = AgentRunner.shared.start(input["message"] as? String ?? "", in: doc.root) { return (err, true) }
            return ("\(doc.name) klasöründe yeni oturum başladı.", false)

        default:
            return ("Bilinmeyen araç.", true)
        }
    }
}
