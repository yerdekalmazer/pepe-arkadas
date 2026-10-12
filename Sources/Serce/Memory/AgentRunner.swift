import Foundation

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

    /// Var olan oturuma yaz. Oturum o an terminalde çalışıyorsa iki kopya çakışmasın diye reddedilir.
    @discardableResult
    func send(_ text: String, to s: AgentSession) -> String? {
        guard s.agent == AgentCatalog.claude else { return "Şimdilik yalnızca Claude Code oturumlarına yazılabiliyor." }
        guard s.status != .working, running[s.id] == nil else { return "\(s.project) şu an çalışıyor; bitince tekrar dene." }
        return launch(key: s.id, cwd: s.cwd, args: ["-p", text, "--resume", s.id])
    }

    /// Bir klasörde yeni oturum başlat (proje hafızası SessionStart hook'uyla kendiliğinden eklenir).
    @discardableResult
    func start(_ text: String, in cwd: String) -> String? {
        guard running[cwd] == nil else { return "Bu klasörde zaten bir iş çalışıyor." }
        return launch(key: cwd, cwd: cwd, args: ["-p", text])
    }

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
