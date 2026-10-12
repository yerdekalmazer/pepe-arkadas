import Foundation

/// Proje başına bir md: ~/Library/Application Support/Serce/Hafiza/<proje>.md
/// (Obsidian'da "(05) Projeler/Serçe Hafızası" bağlantısıyla görünür.)
///
/// Token ilkesi: oturum günlüğü hook verisinden LLM'siz yazılır. LLM yalnızca anlamlı bir oturum bitince,
/// sınırlı bir girdiyle (özet + bu oturumun kısa kaydı) ve yalnızca "Durum / Sıradaki / Kararlar" için çalışır.
@MainActor final class ProjectMemory: ObservableObject {
    static let shared = ProjectMemory()

    /// Test modunda geçici klasöre yönlendirilir.
    nonisolated(unsafe) static var dirOverride: URL?
    nonisolated static var dir: URL { dirOverride ?? Support.dir.appendingPathComponent("Hafiza", isDirectory: true) }

    /// Bir oturumun hafızaya gidecek kısa kaydı (hook'lardan biriktirilir).
    struct SessionLog {
        var root: String
        var agent: String
        var started = Date()
        var lastActivity = Date()
        var stoppedAt: Date?
        var prompts: [String] = []
        var edited: [String] = []
        var commands: [(String, Bool)] = []
        var steps = 0
        var lastReply = ""
    }

    @Published private(set) var lastUpdated: Date?
    private var logs: [String: SessionLog] = [:]
    private var timer: Timer?

    var enabled: Bool { UserDefaults.standard.object(forKey: "hafizaAcik") as? Bool ?? true }
    var llmEnabled: Bool { UserDefaults.standard.object(forKey: "hafizaOzet") as? Bool ?? true }
    var summaryModel: String { UserDefaults.standard.string(forKey: "hafizaModeli") ?? "claude-haiku-5-5" }

    func start() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if !UserDefaults.standard.bool(forKey: "hafizaTohumlandi") {
            UserDefaults.standard.set(true, forKey: "hafizaTohumlandi")
            Self.seedFromNotes()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushIdle() }
        }
    }

    // MARK: - Hook olaylarını biriktir

    /// Test modu: günlüğü beklemeden yaz.
    func flushAllForTest() { for sid in logs.keys { flush(sid) } }

    func observe(_ e: HookEvent) {
        guard enabled else { return }
        let p = e.payload
        guard let sid = p["session_id"] as? String, let cwd = p["cwd"] as? String, !cwd.isEmpty else { return }
        let root = Self.projectRoot(cwd)
        guard !Self.isContainer(root) else { return }
        var log = logs[sid] ?? SessionLog(root: root, agent: AgentCatalog.name(e.agent))
        log.lastActivity = Date()
        let tool = p["tool_name"] as? String ?? ""
        let input = p["tool_input"] as? [String: Any] ?? [:]
        switch e.name {
        case "UserPromptSubmit":
            let text = (p["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { log.prompts.append(String(text.prefix(300))) }
            if log.prompts.count > 6 { log.prompts.removeFirst() }
            log.stoppedAt = nil
        case "PostToolUse":
            log.steps += 1
            if ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool), let f = input["file_path"] as? String {
                let rel = f.hasPrefix(log.root + "/") ? String(f.dropFirst(log.root.count + 1)) : (f as NSString).lastPathComponent
                if !log.edited.contains(rel) { log.edited.append(rel) }
            } else if tool == "Bash", let cmd = input["command"] as? String {
                let r = p["tool_response"] as? [String: Any]
                let ok = !((r?["interrupted"] as? Bool) ?? false)
                    && !(((r?["stdout"] as? String) ?? "").isEmpty && !((r?["stderr"] as? String) ?? "").isEmpty)
                log.commands.append((String(cmd.split(separator: "\n").first ?? "").prefix(100).description, ok))
                if log.commands.count > 12 { log.commands.removeFirst() }
            }
        case "Stop":
            log.stoppedAt = Date()
            if let m = p["last_assistant_message"] as? String, !m.isEmpty { log.lastReply = String(m.suffix(1200)) }
        case "SessionEnd":
            logs[sid] = log
            flush(sid)
            return
        default:
            break
        }
        logs[sid] = log
    }

    /// 20 dk sessiz kalan, durmuş oturumları hafızaya yaz.
    private func flushIdle() {
        let limit = Date().addingTimeInterval(-20 * 60)
        for (sid, log) in logs where (log.stoppedAt ?? .distantFuture) < limit { flush(sid) }
    }

    private func flush(_ sid: String) {
        guard let log = logs.removeValue(forKey: sid), log.steps > 0 || !log.prompts.isEmpty else { return }
        var doc = ProjectDoc.load(root: log.root)
        doc.appendSession(Self.journalEntry(log))
        doc.save()
        lastUpdated = Date()
        // Anlamlı iş yapıldıysa (dosya değişti ya da birkaç komut çalıştı) ve bütçe varsa durumu özetle.
        let meaningful = !log.edited.isEmpty || log.commands.count >= 3
        guard llmEnabled, meaningful, UsageMeter.shared.canSpendBackground, Keychain.get("anthropic") != nil else { return }
        Task { await MemorySummarizer.update(root: log.root, log: log, model: summaryModel) }
    }

    /// LLM'siz günlük girdisi.
    static func journalEntry(_ log: SessionLog) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMM yyyy HH:mm"
        let mins = max(1, Int(log.lastActivity.timeIntervalSince(log.started) / 60))
        var lines = ["### \(f.string(from: log.started)) · \(log.agent) · \(mins) dk"]
        for p in log.prompts.suffix(3) { lines.append("- İstek: \(p.replacingOccurrences(of: "\n", with: " ").prefix(160))") }
        if !log.edited.isEmpty {
            let shown = log.edited.prefix(6).joined(separator: ", ")
            lines.append("- Dosyalar: \(shown)\(log.edited.count > 6 ? " (+\(log.edited.count - 6))" : "")")
        }
        if !log.commands.isEmpty {
            let shown = log.commands.suffix(4).map { "`\($0.0)` \($0.1 ? "✓" : "✗")" }.joined(separator: ", ")
            lines.append("- Komutlar: \(shown)")
        }
        if !log.lastReply.isEmpty {
            let first = log.lastReply.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            lines.append("- Sonuç: \(first.prefix(200))")
        }
        return lines.joined(separator: "\n")
    }

    /// İlk açılışta: Claude hafızasındaki proje notlarında geçen klasörler için md oluşturur (LLM'siz).
    @discardableResult
    static func seedFromNotes() -> Int {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var roots = Set<String>()
        let pathPattern = try! NSRegularExpression(pattern: "~/[^\\s`)\\],;'\"]+")
        let shortPattern = try! NSRegularExpression(pattern: "(?:Projeler/)?(Bireysel|Divizyon|Polenist|Tema|Tipbox-pilot)/[A-Za-z0-9._-]+")
        for proj in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            let mem = base.appendingPathComponent(proj).appendingPathComponent("memory")
            for file in (try? fm.contentsOfDirectory(atPath: mem.path)) ?? [] where file.hasPrefix("project") {
                guard let s = try? String(contentsOf: mem.appendingPathComponent(file), encoding: .utf8) else { continue }
                let ns = s as NSString
                var candidates: [String] = []
                for m in pathPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                    candidates.append(home + ns.substring(with: m.range).dropFirst(1))
                }
                for m in shortPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                    let rel = ns.substring(with: m.range).replacingOccurrences(of: "Projeler/", with: "")
                    candidates.append(home + "/Desktop/Projeler/" + rel)
                }
                for c in candidates {
                    var isDir: ObjCBool = false
                    var trimmed = c
                    while let last = trimmed.last, ".:/ ".contains(last) { trimmed.removeLast() }
                    let rel = trimmed.hasPrefix(home + "/") ? String(trimmed.dropFirst(home.count + 1)) : ""
                    // Gizli klasörler (~/.claude…) ve ~/Library proje değildir.
                    guard !rel.isEmpty, !rel.hasPrefix("."), !rel.hasPrefix("Library"),
                          fm.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue else { continue }
                    let root = projectRoot(trimmed)
                    if isContainer(root) { continue }
                    roots.insert(root)
                    break
                }
            }
        }
        var created = 0
        for root in roots where !fm.fileExists(atPath: ProjectDoc.url(for: root).path) {
            var doc = ProjectDoc.load(root: root)
            doc.save()
            created += 1
        }
        return created
    }

    // MARK: - Proje kimliği

    /// Proje olmayan kapsayıcı klasörler: ev dizini, Masaüstü, kategori klasörleri…
    nonisolated static func isContainer(_ root: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let containers: Set<String> = ["Desktop", "Documents", "Downloads", "Projeler", "Bireysel", "Divizyon",
                                       "Polenist", "Tema", "Tipbox-pilot", "Arşiv", "Arsiv"]
        return root == home || !root.hasPrefix(home + "/") || containers.contains((root as NSString).lastPathComponent)
    }

    /// cwd'den yukarı çıkıp git kökünü bulur; yoksa cwd'nin kendisi.
    nonisolated static func projectRoot(_ cwd: String) -> String {
        var url = URL(fileURLWithPath: cwd)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        while url.path.count > home.count {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return cwd
    }

    // MARK: - Okuma (sohbet, ses, ajan bağlamı)

    nonisolated static func allDocs() -> [ProjectDoc] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasSuffix(".arsiv.md") }
            .compactMap { ProjectDoc.read($0) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    nonisolated static func find(_ name: String) -> ProjectDoc? {
        let q = name.lowercased()
        let docs = allDocs()
        return docs.first { $0.name.lowercased() == q } ?? docs.first { $0.name.lowercased().contains(q) }
            ?? docs.first { $0.root.lowercased().contains(q) }
    }

    /// Yerel metin araması — token harcamaz. Tüm kelimeleri içeren satırlar.
    nonisolated static func search(_ query: String, limit: Int = 12) -> [String] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return [] }
        var hits: [String] = []
        for doc in allDocs() {
            for line in doc.text.components(separatedBy: "\n") {
                let l = line.lowercased()
                if words.allSatisfy({ l.contains($0) }) {
                    hits.append("\(doc.name): \(line.trimmingCharacters(in: .whitespaces).prefix(220))")
                    if hits.count >= limit { return hits }
                }
            }
        }
        return hits
    }

    /// Claude Code SessionStart'a eklenecek kısa bağlam (~400 token). Proje md'si yoksa nil.
    nonisolated static func sessionContext(cwd: String) -> String? {
        guard UserDefaults.standard.object(forKey: "hafizaBaglam") as? Bool ?? true else { return nil }
        let root = projectRoot(cwd)
        guard !isContainer(root), let doc = ProjectDoc.read(ProjectDoc.url(for: root)) else { return nil }
        var parts = ["Serçe proje hafızası (\(doc.name)) — kısa özet; ayrıntı: \(ProjectDoc.url(for: root).path)"]
        for (title, cap) in [("Özet", 500), ("Durum", 400), ("Sıradaki", 400)] {
            let body = doc.section(title).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty, !body.hasPrefix("_") { parts.append("\(title): \(body.prefix(cap))") }
        }
        // Son oturum tam (kısaltılmış), öncekiler yalnızca başlık.
        let entries = doc.section("Oturumlar").components(separatedBy: "\n### ").filter { !$0.isEmpty }
        if let last = entries.first {
            let body = last.hasPrefix("### ") ? String(last.dropFirst(4)) : last
            parts.append("Son oturum: " + body.prefix(450))
        }
        let older = entries.dropFirst().prefix(2).compactMap { $0.components(separatedBy: "\n").first }
        if !older.isEmpty { parts.append("Önceki: " + older.joined(separator: " | ")) }
        let text = parts.joined(separator: "\n")
        return String(text.prefix(1600))
    }
}

/// Bir proje md'si: frontmatter + "## " bölümleri. Kullanıcının elle eklediği bölümler korunur.
struct ProjectDoc {
    static let order = ["Özet", "Durum", "Sıradaki", "Kararlar", "Notlar", "Oturumlar"]
    static let maxSessions = 15

    var url: URL
    var name: String
    var root: String
    var updated: String
    var sections: [(String, String)]

    var text: String { render() }

    func section(_ title: String) -> String { sections.first { $0.0 == title }?.1 ?? "" }

    mutating func setSection(_ title: String, _ body: String) {
        if let i = sections.firstIndex(where: { $0.0 == title }) { sections[i].1 = body } else { sections.append((title, body)) }
    }

    static func url(for root: String) -> URL {
        let name = (root as NSString).lastPathComponent
        let safe = name.map { "/:\\".contains($0) ? "-" : $0 }.map(String.init).joined()
        return ProjectMemory.dir.appendingPathComponent(safe + ".md")
    }

    static func read(_ url: URL) -> ProjectDoc? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var name = url.deletingPathExtension().lastPathComponent, root = "", updated = ""
        var body = s
        if s.hasPrefix("---\n"), let end = s.range(of: "\n---\n", range: s.index(s.startIndex, offsetBy: 4)..<s.endIndex) {
            for line in s[s.index(s.startIndex, offsetBy: 4)..<end.lowerBound].components(separatedBy: "\n") {
                let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "proje": name = kv[1]
                case "klasor": root = (kv[1] as NSString).expandingTildeInPath
                case "guncellendi": updated = kv[1]
                default: break
                }
            }
            body = String(s[end.upperBound...])
        }
        var sections: [(String, String)] = []
        var current: String?
        var buf: [String] = []
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if let c = current { sections.append((c, buf.joined(separator: "\n").trimmingCharacters(in: .newlines))) }
                current = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                buf = []
            } else if current != nil {
                buf.append(line)
            }
        }
        if let c = current { sections.append((c, buf.joined(separator: "\n").trimmingCharacters(in: .newlines))) }
        return ProjectDoc(url: url, name: name, root: root, updated: updated, sections: sections)
    }

    /// Varsa okur; yoksa şablonla oluşturur ve Claude hafızasındaki proje notundan özet tohumlar (LLM'siz).
    static func load(root: String) -> ProjectDoc {
        let u = url(for: root)
        if let d = read(u) { return d }
        let name = (root as NSString).lastPathComponent
        var d = ProjectDoc(url: u, name: name, root: root, updated: "", sections: [])
        d.setSection("Özet", seedSummary(root: root) ?? "_Bu projenin ne olduğunu bir iki cümleyle yaz; Serçe ve ajanlar bunu okur._")
        d.setSection("Durum", "_Henüz özet yok._")
        d.setSection("Sıradaki", "")
        d.setSection("Kararlar", "")
        d.setSection("Notlar", "")
        d.setSection("Oturumlar", "")
        return d
    }

    /// ~/.claude/projects/*/memory altında bu klasörü anan bir proje notu varsa açıklamasını ve ilk paragrafını alır.
    private static func seedSummary(root: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let rel = root.hasPrefix(home) ? String(root.dropFirst(home.count + 1)) : root
        let tail = rel.components(separatedBy: "/").suffix(2).joined(separator: "/")
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        for proj in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            let mem = base.appendingPathComponent(proj).appendingPathComponent("memory")
            for file in (try? fm.contentsOfDirectory(atPath: mem.path)) ?? [] where file.hasPrefix("project") {
                guard let s = try? String(contentsOf: mem.appendingPathComponent(file), encoding: .utf8),
                      s.contains(tail) || s.contains(rel) else { continue }
                var desc = ""
                if let r = s.range(of: "description:") {
                    desc = String(s[r.upperBound...].prefix { $0 != "\n" }).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                }
                let body = s.components(separatedBy: "\n---\n").last ?? ""
                let para = body.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n").first ?? ""
                return [desc, String(para.prefix(500))].filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
        }
        return nil
    }

    mutating func appendSession(_ entry: String) {
        var entries = section("Oturumlar").components(separatedBy: "\n### ").map { $0.hasPrefix("### ") ? $0 : "### " + $0 }
            .filter { $0.count > 4 }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxSessions {
            // Taşanlar LLM'siz arşive gider.
            let overflow = entries[Self.maxSessions...].joined(separator: "\n\n")
            entries = Array(entries.prefix(Self.maxSessions))
            let archive = url.deletingPathExtension().appendingPathExtension("arsiv.md")
            let old = (try? String(contentsOf: archive, encoding: .utf8)) ?? "# \(name) — eski oturumlar\n"
            try? (old + "\n" + overflow + "\n").write(to: archive, atomically: true, encoding: .utf8)
        }
        setSection("Oturumlar", entries.joined(separator: "\n\n"))
    }

    mutating func save() {
        updated = UsageMeter.dayKey(Date())
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? render().write(to: url, atomically: true, encoding: .utf8)
    }

    private func render() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shownRoot = root.hasPrefix(home) ? "~" + root.dropFirst(home.count) : root
        var out = "---\nproje: \(name)\nklasor: \(shownRoot)\nguncellendi: \(updated)\nkaynak: Serçe\n---\n\n# \(name)\n"
        let known = Self.order.compactMap { t in sections.first { $0.0 == t } }
        let extra = sections.filter { s in !Self.order.contains(s.0) }
        for (title, body) in known.dropLast() + extra + known.suffix(1) {
            out += "\n## \(title)\n\(body.isEmpty ? "" : body + "\n")"
        }
        return out
    }
}
