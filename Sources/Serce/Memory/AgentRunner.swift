import AppKit

/// Pepe'den bir ajan oturumu başlatmak ya da var olanına mesaj göndermek: terminal açık olmasına gerek yok.
/// Claude Code: `claude -p <mesaj> --resume <oturum>`; adımlar, izinler ve son yanıt kurulu hook'larla notch'a gelir.
/// Codex (`codex exec --json`) ve Gemini CLI (`gemini -p … -o stream-json`): olay akışı AgentStream'le okunur.
@MainActor final class AgentRunner: ObservableObject {
    static let shared = AgentRunner()

    /// Pepe'nin şu an yürüttüğü işler: oturum kimliği (yeni oturumda klasör) → süreç.
    @Published private(set) var running: [String: Process] = [:]
    @Published private(set) var lastError: [String: String] = [:]
    /// Son çalıştırmanın sonucu ve oturum kimliği (yeni oturumlar için).
    @Published private(set) var lastResult: [String: (text: String, sessionId: String)] = [:]

    /// Codex oturum kimliğini çalışmaya başlayınca bildirir; o zamana kadar geçici anahtarla izlenir.
    private var aliases: [String: String] = [:]
    private var streams: [String: AgentStream] = [:]

    func isRunning(_ key: String) -> Bool { running[key] != nil }

    /// Olayları Pepe'nin kendisinin akıştan okuduğu (Codex/Gemini) bir çalıştırma mı?
    func isStreaming(_ sid: String) -> Bool { streams[sid] != nil }

    /// Pepe'den yazılabilen oturumlar.
    static func canWrite(_ agent: String) -> Bool { RunnableAgent(agent: agent) != nil }

    /// Pepe'den gönderilen mesajlar için oturum başına seçimler (nil = Claude Code'daki/oturumdaki gibi).
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
        ("auto", "Otomatik", "Claude güvenli bulduklarını kendisi onaylar; terminaldeki oturuma da sonraki izinde uygulanır"),
        ("plan", "Plan", "Değişiklik yapmaz, yalnızca plan çıkarır"),
        ("dontAsk", "Sorma", "İzin gerektireni sormadan reddeder"),
        ("bypassPermissions", "Tüm izinleri atla ⚠︎", "Hiçbir şey sormaz — yalnızca Pepe'den gönderilenlerde; terminaldeki oturuma uygulanamaz"),
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

    /// Oturumun seçimleri; hiç seçilmediyse ajanın varsayılanı (Claude'da model genel "arka plan modeli"nden gelir).
    func options(for sid: String, agent: String = AgentCatalog.claude) -> RunOptions {
        options[sid] ?? (RunnableAgent(agent: agent) ?? .claude).defaultOptions
    }

    func setOptions(_ o: RunOptions, for sid: String) {
        options[sid] = o
        // Son 200 oturum saklanır.
        if options.count > 200, let k = options.keys.first { options.removeValue(forKey: k) }
        if let d = try? JSONEncoder().encode(options) { UserDefaults.standard.set(d, forKey: "oturumAyarlari") }
    }

    /// Var olan oturuma yaz. Oturum o an terminalde çalışıyorsa iki kopya çakışmasın diye reddedilir.
    @discardableResult
    func send(_ text: String, images: [Data] = [], to s: AgentSession) -> String? {
        guard let agent = RunnableAgent(agent: s.agent) else { return "\(s.agentName) oturumlarına şimdilik yazılamıyor." }
        guard s.status != .working, running[s.id] == nil else { return "\(s.project) şu an çalışıyor; bitince tekrar dene." }
        let o = options(for: s.id, agent: s.agent)
        switch agent {
        case .codex:
            let files = Self.imageFiles(images)
            let args = ["exec", "resume", "--json", "--skip-git-repo-check"] + agent.codexArgs(o)
                + files.flatMap { ["-i", $0] } + ["--", s.id, text]
            return launchResumed(agent, s, args: args, text: text)
        case .gemini:
            // Gemini görselleri @yol ile okur.
            let prompt = ([text] + Self.imageFiles(images).map { "@" + $0 }).joined(separator: " ")
            let args = ["--prompt=" + prompt, "--resume", s.id, "-o", "stream-json", "--skip-trust"] + agent.geminiArgs(o)
            return launchResumed(agent, s, args: args, text: text)
        case .claude:
            break
        }
        let opts = o.args
        guard !images.isEmpty else {
            return launch(.claude, key: s.id, cwd: s.cwd, args: ["-p", text, "--resume", s.id] + opts)
        }
        // Görselli mesaj: terminale yapıştırılmış gibi gerçek görsel bloğu olarak, JSON akışıyla gönderilir.
        var content: [[String: Any]] = []
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        for d in images {
            guard case .image(let mime, let b64)? = AttachmentReader.imagePart(d) else { continue }
            content.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": b64]])
        }
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard var line = try? JSONSerialization.data(withJSONObject: msg) else { return "Görsel hazırlanamadı." }
        line.append(0x0A)
        return launch(.claude, key: s.id, cwd: s.cwd, args: ["-p", "--input-format", "stream-json", "--verbose", "--resume", s.id] + opts,
                      stdin: line)
    }

    /// Var olan Codex/Gemini oturumuna yazmak: istek karta hemen düşer, olaylar akıştan gelir.
    private func launchResumed(_ agent: RunnableAgent, _ s: AgentSession, args: [String], text: String) -> String? {
        let stream = AgentStream(agent: agent, cwd: s.cwd, prompt: text, sessionId: s.id)
        if let err = launch(agent, key: s.id, cwd: s.cwd, args: args, stream: stream) { return err }
        stream.begin()
        return nil
    }

    /// Pepe'nin başlattığı oturumların modeli (nil = Claude Code'daki varsayılan). Token tasarrufu için ayarlanabilir.
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

    /// Projesiz oturumların çalıştığı klasör: bir projeye bağlı olmayan genel Claude oturumları için.
    nonisolated static let projectlessDir = Support.dir.appendingPathComponent("Projesiz").path

    /// Bir projede yeni oturum başlat; aynı projede istediğin kadar (en fazla `maxParallel`) paralel çalışabilir.
    /// `worktree` açıksa oturum ayrı bir git çalışma kopyasında çalışır, diğerleriyle aynı dosyaları ezmez.
    /// Proje hafızası SessionStart hook'uyla kendiliğinden eklenir.
    @discardableResult
    func start(_ text: String, in cwd: String, worktree: Bool = false, agent: RunnableAgent = .claude) -> String? {
        let opts = pendingOptions ?? agent.defaultOptions
        pendingOptions = nil
        guard running.count < maxParallel else { return "Aynı anda en fazla \(maxParallel) oturum çalışabilir; biri bitince tekrar dene." }
        guard agent.installed else { return "\(agent.rawValue) komutu bulunamadı." }
        let isGit = ProjectMemory.projectRoot(cwd) != cwd || FileManager.default.fileExists(atPath: cwd + "/.git")
        if worktree, !isGit { return "Ayrı çalışma kopyası için proje bir git deposu olmalı." }
        let sid = UUID().uuidString.lowercased()
        switch agent {
        case .claude:
            var args = ["-p", text, "--session-id", sid, "-n", String(text.prefix(40))]
            args += opts.args
            if worktree { args += ["--worktree", "serce-" + sid.prefix(6)] }
            if let err = launch(.claude, key: sid, cwd: cwd, args: args) { return err }
            setOptions(opts, for: sid)
            AppState.shared.store.registerLaunched(id: sid, cwd: cwd, prompt: text)
        case .gemini:
            var dir = cwd
            if worktree {
                switch Self.makeWorktree(in: cwd, name: "serce-" + sid.prefix(6)) {
                case .success(let path): dir = path
                case .failure(let e): return e.message
                }
            }
            let args = ["--prompt=" + text, "--session-id", sid, "-o", "stream-json", "--skip-trust"] + agent.geminiArgs(opts)
            let stream = AgentStream(agent: agent, cwd: dir, prompt: text, sessionId: sid)
            if let err = launch(agent, key: sid, cwd: dir, args: args, stream: stream) { return err }
            setOptions(opts, for: sid)
            AppState.shared.store.registerLaunched(id: sid, cwd: dir, prompt: text, agent: agent.rawValue)
            stream.begin()
        case .codex:
            var dir = cwd
            if worktree {
                switch Self.makeWorktree(in: cwd, name: "serce-" + sid.prefix(6)) {
                case .success(let path): dir = path
                case .failure(let e): return e.message
                }
            }
            // Codex oturum kimliğini ilk satırda verir; kart o zaman açılır, seçimler o kimliğe taşınır.
            let stream = AgentStream(agent: agent, cwd: dir, prompt: text, sessionId: nil)
            let tmp = "yeni-" + sid
            stream.onSessionId = { [weak self] id in
                guard let self else { return }
                self.aliases[tmp] = id
                if let p = self.running.removeValue(forKey: tmp) { self.running[id] = p }
                if let st = self.streams.removeValue(forKey: tmp) { self.streams[id] = st }
                self.setOptions(opts, for: id)
                AppState.shared.store.registerLaunched(id: id, cwd: dir, prompt: text, agent: agent.rawValue)
            }
            let args = ["exec", "--json", "--skip-git-repo-check"] + agent.codexArgs(opts) + ["--", text]
            if let err = launch(agent, key: tmp, cwd: dir, args: args, stream: stream) { return err }
        }
        return nil
    }

    struct RunError: Error { let message: String }

    /// Codex ve Gemini için ayrı git çalışma kopyası: <proje>/.worktrees/<ad>, git'in görmezden geldiği bir klasörde.
    static func makeWorktree(in cwd: String, name: String) -> Result<String, RunError> {
        let root = ProjectMemory.projectRoot(cwd)
        let path = root + "/.worktrees/" + name
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root, "worktree", "add", "-b", name, path]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return .failure(RunError(message: "git çalıştırılamadı.")) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(RunError(message: "Çalışma kopyası açılamadı: " + msg.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
        }
        // Ana depoda izlenmeyen dosya olarak görünmesin.
        let exclude = root + "/.git/info/exclude"
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        if !current.contains(".worktrees/") {
            try? FileManager.default.createDirectory(atPath: root + "/.git/info", withIntermediateDirectories: true)
            try? (current + (current.hasSuffix("\n") || current.isEmpty ? "" : "\n") + ".worktrees/\n")
                .write(toFile: exclude, atomically: true, encoding: .utf8)
        }
        return .success(path)
    }

    /// Codex `-i dosya`, Gemini `@dosya` ister: görseller geçici PNG olarak yazılır.
    private static func imageFiles(_ images: [Data]) -> [String] {
        images.compactMap { d in
            guard let png = NSBitmapImageRep(data: d)?.representation(using: .png, properties: [:]) else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pepe-\(UUID().uuidString.prefix(8)).png")
            return (try? png.write(to: url)) == nil ? nil : url.path
        }
    }

    /// Pepe'nin yürüttüğü oturumu gerçek bir terminalde devral (`claude --resume`, `codex resume`, `gemini --resume`).
    func openInTerminal(_ s: AgentSession) -> String? {
        guard running[s.id] == nil else { return "Önce Pepe'deki çalışma bitsin; iki kopya aynı oturumu sürmesin." }
        let agent = RunnableAgent(agent: s.agent) ?? .claude
        guard let bin = agent.path else { return "\(agent.rawValue) komutu bulunamadı." }
        let resume = ([Self.quote(bin)] + agent.resumeArgs(s.id)).joined(separator: " ")
        let cmd = "cd \(Self.quote(s.cwd)) && \(resume)"
        if let ghostty = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // Kabuk üzerinden: Claude çıkınca pencere kapanmasın, terminal açık kalsın.
            p.arguments = ["-na", ghostty.path, "--args", "--working-directory=\(s.cwd)", "-e", "/bin/zsh", "-lc",
                           "\(resume); exec /bin/zsh -l"]
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

    private func launch(_ agent: RunnableAgent, key: String, cwd: String, args: [String], stdin: Data? = nil,
                        stream: AgentStream? = nil) -> String? {
        guard let bin = agent.path else { return "\(agent.rawValue) komutu bulunamadı." }
        guard FileManager.default.fileExists(atPath: cwd) else { return "Klasör yok: \(cwd)" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        // Claude: izin gerektiren araçlar PermissionRequest hook'uyla notch'a düşer; hook kurulu değilse reddedilir.
        // Akış biçimi: init satırındaki komut listesi (/ önerileri için) de gelir.
        p.arguments = agent == .claude ? args + (args.contains("--verbose") ? [] : ["--verbose"]) + ["--output-format", "stream-json"] : args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env["SERCE_RUN"] = "1"
        if stream != nil {
            // Olaylar akıştan okunur; ajanın hook'ları aynı olayları ikinci kez göndermesin.
            env["SERCE_STREAM"] = "1"
        }
        if agent == .gemini, env["GEMINI_API_KEY"] == nil, let key = Keychain.get("gemini") {
            // Sohbet için girilen Gemini anahtarı Gemini CLI'a da verilir (Google hesabıyla girişte kullanılmaz).
            env["GEMINI_API_KEY"] = key
        }
        p.environment = env
        // Çıktı sürekli okunur: akış modunda tampon dolup süreç kilitlenmesin. Codex/Gemini satırları canlı işlenir.
        let out = Pipe()
        let collected = OutputBuffer()
        let lines = stream.map { st in LineSplitter { line in DispatchQueue.main.async { MainActor.assumeIsolated { st.feed(line) } } } }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            collected.append(d)
            lines?.append(d)
        }
        p.standardOutput = out
        let err = Pipe()
        let errText = OutputBuffer()
        err.fileHandleForReading.readabilityHandler = { h in errText.append(h.availableData) }
        p.standardError = err
        let input = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            collected.append(rest)
            lines?.append(rest)
            lines?.finish()
            let status = proc.terminationStatus
            let data = collected.data
            let stderr = String(decoding: errText.data.suffix(4000), as: UTF8.self)
            // Satırlarla aynı kuyrukta: önce son satırlar işlenir, sonra bitiş.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentRunner.shared.finished(key, status: status, output: data, stderr: stderr) }
            }
        }
        do { try p.run() } catch { return "Başlatılamadı: \(error.localizedDescription)" }
        if let stdin {
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }
        running[key] = p
        if let stream { streams[key] = stream }
        lastError[key] = nil
        return nil
    }

    private func finished(_ launchKey: String, status: Int32, output: Data, stderr: String) {
        let key = aliases.removeValue(forKey: launchKey) ?? launchKey
        running[key] = nil
        defer { ComposerStore.shared.flush(key) }
        if let stream = streams.removeValue(forKey: key) {
            stream.end(status: status, stderr: stderr)
            if let e = stream.error { lastError[key] = e }
            lastResult[key] = (stream.lastText, stream.sessionId ?? "")
            return
        }
        SlashCommands.record(from: output)
        // Düz JSON (tek nesne) ya da akış (satır satır; sonuç "result" satırında).
        var json = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
        if json == nil {
            json = output.split(separator: 0x0A).reversed().lazy
                .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                .first { $0["type"] as? String == "result" }
        }
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

/// Akıştaki baytları satırlara böler (JSON satırları parça parça gelebilir).
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: (Data) -> Void
    init(_ onLine: @escaping (Data) -> Void) { self.onLine = onLine }

    func append(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock()
        pending.append(d)
        var lines: [Data] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<nl])
            pending.removeSubrange(pending.startIndex...nl)
        }
        lock.unlock()
        for l in lines where !l.isEmpty { onLine(Data(l)) }
    }

    func finish() {
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()
        if !rest.isEmpty { onLine(rest) }
    }
}

/// Süreç çıktısını iş parçacığı güvenli biriktirir.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    func append(_ d: Data) { guard !d.isEmpty else { return }; lock.lock(); buf.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buf }
}
