import AppKit

/// Serçe'den bir Claude Code oturumuna mesaj göndermek: terminal açık olmasına gerek yok.
/// `claude -p <mesaj> --resume <oturum>` oturumun klasöründe arka planda çalışır; adımlar, izinler ve
/// son yanıt kurulu hook'lar sayesinde her zamanki gibi notch'ta görünür.
@MainActor final class AgentRunner: ObservableObject {
    static let shared = AgentRunner()

    /// Serçe'nin şu an yürüttüğü işler: oturum kimliği (yeni oturumda klasör) → süreç.
    @Published private(set) var running: [String: Process] = [:]
    @Published private(set) var lastError: [String: String] = [:]
    /// Son çalıştırmanın sonucu ve oturum kimliği (yeni oturumlar için).
    @Published private(set) var lastResult: [String: (text: String, sessionId: String)] = [:]

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func isRunning(_ key: String) -> Bool { running[key] != nil }

    /// Serçe'den gönderilen mesajlar için oturum başına seçimler (nil = Claude Code'daki/oturumdaki gibi).
    struct RunOptions: Codable, Equatable {
        var mode: String?
        var model: String?
        var effort: String?

        var args: [String] {
            var a: [String] = []
            if let mode { a += ["--permission-mode", mode] }
            if let model { a += ["--model", model] }
            if let effort { a += ["--effort", effort] }
            return a
        }
    }

    static let modes: [(id: String?, title: String, hint: String)] = [
        (nil, "Oturumdaki gibi", "Claude Code ayarların neyse o"),
        ("manual", "Sor", "Her izinde notch'ta sorar"),
        ("acceptEdits", "Düzenlemeleri kabul et", "Dosya düzenlemeleri sormadan, komutlar sorarak"),
        ("auto", "Otomatik", "Claude güvenli bulduklarını kendisi onaylar"),
        ("plan", "Plan", "Değişiklik yapmaz, yalnızca plan çıkarır"),
        ("dontAsk", "Sorma", "İzin gerektireni sormadan reddeder"),
        ("bypassPermissions", "Tüm izinleri atla ⚠︎", "Hiçbir şey sormaz — dikkat"),
    ]
    static let models: [(id: String?, title: String)] = [
        (nil, "Varsayılan"), ("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"),
    ]
    static let efforts: [String?] = [nil, "low", "medium", "high", "xhigh", "max"]

    @Published private(set) var options: [String: RunOptions] = {
        guard let d = UserDefaults.standard.data(forKey: "oturumAyarlari"),
              let v = try? JSONDecoder().decode([String: RunOptions].self, from: d) else { return [:] }
        return v
    }()

    /// Oturumun seçimleri; hiç seçilmediyse model genel "arka plan modeli"nden gelir.
    func options(for sid: String) -> RunOptions {
        options[sid] ?? RunOptions(mode: nil, model: Self.model, effort: nil)
    }

    func setOptions(_ o: RunOptions, for sid: String) {
        options[sid] = o
        // Son 200 oturum saklanır.
        if options.count > 200, let k = options.keys.first { options.removeValue(forKey: k) }
        if let d = try? JSONEncoder().encode(options) { UserDefaults.standard.set(d, forKey: "oturumAyarlari") }
    }

    /// Var olan oturuma yaz. Oturum o an terminalde çalışıyorsa iki kopya çakışmasın diye reddedilir.
    @discardableResult
    func send(_ text: String, to s: AgentSession) -> String? {
        guard s.agent == AgentCatalog.claude else { return "Şimdilik yalnızca Claude Code oturumlarına yazılabiliyor." }
        guard s.status != .working, running[s.id] == nil else { return "\(s.project) şu an çalışıyor; bitince tekrar dene." }
        return launch(key: s.id, cwd: s.cwd, args: ["-p", text, "--resume", s.id] + options(for: s.id).args)
    }

    /// Serçe'nin başlattığı oturumların modeli (nil = Claude Code'daki varsayılan). Token tasarrufu için ayarlanabilir.
    nonisolated(unsafe) static var modelOverride: String?
    static var model: String? { modelOverride ?? UserDefaults.standard.string(forKey: "arkaPlanModel").flatMap { $0.isEmpty ? nil : $0 } }

    /// Yeni oturum ekranında seçilen ayarlar; bir sonraki start() kullanır.
    var pendingOptions: RunOptions?

    /// Aynı anda en fazla kaç terminalsiz oturum (maliyet freni).
    var maxParallel: Int { UserDefaults.standard.object(forKey: "paralelOturum") as? Int ?? 4 }

    /// Projede başka bir oturum çalışıyor mu? (Yeni oturum ayrı çalışma kopyasında açılmalı mı kararı için.)
    func hasActiveSession(in cwd: String) -> Bool {
        let name = ProjectNames.name(for: cwd)
        return AppState.shared.store.sessions.contains { $0.project == name && ($0.status == .working || running[$0.id] != nil) }
    }

    /// Bir projede yeni oturum başlat; aynı projede istediğin kadar (en fazla `maxParallel`) paralel çalışabilir.
    /// `worktree` açıksa oturum ayrı bir git çalışma kopyasında çalışır, diğerleriyle aynı dosyaları ezmez.
    /// Proje hafızası SessionStart hook'uyla kendiliğinden eklenir.
    @discardableResult
    func start(_ text: String, in cwd: String, worktree: Bool = false) -> String? {
        guard running.count < maxParallel else { return "Aynı anda en fazla \(maxParallel) oturum çalışabilir; biri bitince tekrar dene." }
        let isGit = ProjectMemory.projectRoot(cwd) != cwd || FileManager.default.fileExists(atPath: cwd + "/.git")
        if worktree, !isGit { return "Ayrı çalışma kopyası için proje bir git deposu olmalı." }
        let sid = UUID().uuidString.lowercased()
        var args = ["-p", text, "--session-id", sid, "-n", String(text.prefix(40))]
        let opts = pendingOptions ?? RunOptions(mode: nil, model: Self.model, effort: nil)
        pendingOptions = nil
        args += opts.args
        setOptions(opts, for: sid)
        if worktree { args += ["--worktree", "serce-" + sid.prefix(6)] }
        if let err = launch(key: sid, cwd: cwd, args: args) { return err }
        AppState.shared.store.registerLaunched(id: sid, cwd: cwd, prompt: text)
        return nil
    }

    /// Serçe'nin yürüttüğü oturumu gerçek bir terminalde devral (`claude --resume`).
    func openInTerminal(_ s: AgentSession) -> String? {
        guard running[s.id] == nil else { return "Önce Serçe'deki çalışma bitsin; iki kopya aynı oturumu sürmesin." }
        guard let claude = Self.claudePath else { return "claude komutu bulunamadı." }
        let cmd = "cd \(Self.quote(s.cwd)) && \(Self.quote(claude)) --resume \(s.id)"
        if let ghostty = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // Kabuk üzerinden: Claude çıkınca pencere kapanmasın, terminal açık kalsın.
            p.arguments = ["-na", ghostty.path, "--args", "--working-directory=\(s.cwd)", "-e", "/bin/zsh", "-lc",
                           "\(Self.quote(claude)) --resume \(s.id); exec /bin/zsh -l"]
            try? p.run()
            return nil
        }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Terminal\" to do script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\"\ntell application \"Terminal\" to activate")?
            .executeAndReturnError(&error)
        return error == nil ? nil : "Terminal açılamadı."
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func stop(_ key: String) {
        running[key]?.interrupt()
    }

    private func launch(key: String, cwd: String, args: [String]) -> String? {
        guard let claude = Self.claudePath else { return "claude komutu bulunamadı." }
        guard FileManager.default.fileExists(atPath: cwd) else { return "Klasör yok: \(cwd)" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        // İzin gerektiren araçlar PermissionRequest hook'uyla notch'a düşer; hook kurulu değilse reddedilir.
        p.arguments = args + ["--output-format", "json"]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env["SERCE_RUN"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let status = proc.terminationStatus
            Task { @MainActor in AgentRunner.shared.finished(key, status: status, output: data) }
        }
        do { try p.run() } catch { return "Başlatılamadı: \(error.localizedDescription)" }
        running[key] = p
        lastError[key] = nil
        return nil
    }

    private func finished(_ key: String, status: Int32, output: Data) {
        running[key] = nil
        let json = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
        if status != 0 || (json?["is_error"] as? Bool) == true {
            lastError[key] = (json?["result"] as? String).map { String($0.prefix(300)) } ?? "claude \(status) koduyla çıktı."
        }
        lastResult[key] = (json?["result"] as? String ?? "", json?["session_id"] as? String ?? "")
        if let cost = json?["total_cost_usd"] as? Double, cost > 0 {
            // Claude Code kendi aboneliğinle/anahtarınla çalışır; tahmini maliyet yine de sayaçta görünür.
            UsageMeter.shared.recordCost(cost, purpose: .agent)
        }
    }
}
