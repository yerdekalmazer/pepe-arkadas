import Foundation
import SwiftUI

struct PlanWindow: Equatable {
    var usedPct: Double
    var resetsAt: Date
    /// Sıfırlanma zamanı geçtiyse kullanım 0 sayılır.
    var effectivePct: Double { resetsAt <= Date() ? 0 : usedPct }
}

struct PlanUsage: Equatable {
    var fiveHour: PlanWindow?
    var sevenDay: PlanWindow?
    var planType: String?
    var resetCredits: Int?
    var updatedAt = Date()

    /// İki penceredeki en yüksek kullanım; pill'de bu gösterilir.
    var dominant: PlanWindow? {
        [fiveHour, sevenDay].compactMap { $0 }.max { $0.effectivePct < $1.effectivePct }
    }

    /// Claude Code durum satırı yükündeki rate_limits (used_percentage, resets_at saniye).
    static func fromClaude(_ payload: [String: Any]) -> PlanUsage? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        func window(_ raw: Any?) -> PlanWindow? {
            guard let d = raw as? [String: Any],
                  let pct = (d["used_percentage"] as? NSNumber)?.doubleValue, (0...200).contains(pct),
                  let epoch = (d["resets_at"] as? NSNumber)?.doubleValue, epoch > 0,
                  epoch < Date().timeIntervalSince1970 + 400 * 86400 else { return nil }
            return PlanWindow(usedPct: min(100, pct), resetsAt: Date(timeIntervalSince1970: epoch))
        }
        let u = PlanUsage(fiveHour: window(limits["five_hour"]), sevenDay: window(limits["seven_day"]))
        return u.fiveHour == nil && u.sevenDay == nil ? nil : u
    }

    /// `codex app-server` → account/rateLimits/read sonucu.
    static func fromCodex(_ result: [String: Any]) -> PlanUsage? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var u = PlanUsage(planType: limits["planType"] as? String)
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any],
                  let pct = (w["usedPercent"] as? NSNumber)?.doubleValue,
                  let resets = (w["resetsAt"] as? NSNumber)?.doubleValue else { continue }
            let win = PlanWindow(usedPct: min(100, max(0, pct)), resetsAt: Date(timeIntervalSince1970: resets))
            if let mins = (w["windowDurationMins"] as? NSNumber)?.intValue, mins <= 24 * 60 { u.fiveHour = win } else { u.sevenDay = win }
        }
        if let credits = result["rateLimitResetCredits"] as? [String: Any] { u.resetCredits = credits["availableCount"] as? Int }
        return u.fiveHour == nil && u.sevenDay == nil ? nil : u
    }
}

@MainActor final class PlanStore: ObservableObject {
    static let shared = PlanStore()

    @Published private(set) var claude: PlanUsage?
    @Published private(set) var codex: PlanUsage?
    /// Üst çubuktaki pill'e tıklanınca panelde ayrıntı açılır.
    @Published var showDetail = false
    @Published var showClaude = UserDefaults.standard.bool(forKey: "planClaude") {
        didSet { UserDefaults.standard.set(showClaude, forKey: "planClaude") }
    }
    @Published var showCodex = UserDefaults.standard.bool(forKey: "planCodex") {
        didSet {
            UserDefaults.standard.set(showCodex, forKey: "planCodex")
            if showCodex { refreshCodex() }
        }
    }
    private var timer: Timer?

    var isVisible: Bool { (showClaude && claude != nil) || (showCodex && codex != nil) }

    func updateClaude(from payload: [String: Any]) {
        if let u = PlanUsage.fromClaude(payload) { claude = u }
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in PlanStore.shared.refreshCodex() }
        }
        refreshCodex()
    }

    func refreshCodex() {
        guard showCodex else { return }
        Task.detached {
            let u = CodexRateLimits.read()
            await MainActor.run { if let u { PlanStore.shared.codex = u } }
        }
    }

    // Test ve anlık görüntü için
    func setForPreview(claude: PlanUsage?, codex: PlanUsage?) {
        self.claude = claude
        self.codex = codex
    }
}

/// Codex'in /status ekranının kaynağı: `codex app-server` JSON-RPC.
enum CodexRateLimits {
    static func executable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex",
                "\(home)/.bun/bin/codex"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func read() -> PlanUsage? {
        guard let codex = executable() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [URL(fileURLWithPath: codex).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: killer)
        defer { killer.cancel() }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"serce","version":"1"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      (obj["id"] as? NSNumber)?.intValue == 2 else { continue }
                return (obj["result"] as? [String: Any]).flatMap(PlanUsage.fromCodex)
            }
        }
    }
}

/// Claude Code'un statusLine'ını Serçe'ye yönlendirir; kullanıcının önceki komutu saklanır ve çalışmaya devam eder.
enum StatusLineInstaller {
    nonisolated(unsafe) static var previousURL = Support.dir.appendingPathComponent("statusline-previous.json")
    static var settingsURL: URL { HookInstaller.settingsURL }

    static func isInstalled() -> Bool {
        guard let root = try? load(), let sl = root["statusLine"] as? [String: Any] else { return false }
        return (sl["command"] as? String ?? "").contains("serce-hook")
    }

    static func install() throws {
        var root = try load()
        if let prev = root["statusLine"] as? [String: Any], !((prev["command"] as? String ?? "").contains("serce-hook")) {
            let data = try JSONSerialization.data(withJSONObject: prev, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: previousURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: previousURL, options: .atomic)
        }
        var sl: [String: Any] = ["type": "command", "command": "'\(Support.hookURL.path)' --statusline"]
        if let prev = root["statusLine"] as? [String: Any], let pad = prev["padding"] { sl["padding"] = pad }
        root["statusLine"] = sl
        try save(root)
    }

    static func uninstall() throws {
        var root = try load()
        guard isInstalled() else { return }
        if let data = try? Data(contentsOf: previousURL),
           let prev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root["statusLine"] = prev
        } else {
            root.removeValue(forKey: "statusLine")
        }
        try save(root)
        try? FileManager.default.removeItem(at: previousURL)
    }

    private static func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw HookInstaller.Failure.unreadable }
        return obj
    }

    private static func save(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = settingsURL.appendingPathExtension("serce-yedek")
        if fm.fileExists(atPath: settingsURL.path) {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}

// MARK: - Görünümler

enum PlanStyle {
    static func color(_ pct: Double?) -> Color {
        guard let pct else { return .white.opacity(0.5) }
        return pct < 50 ? Palette.green : (pct < 80 ? Palette.amber : Palette.red)
    }

    static func remaining(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)g \(h)s" }
        if h > 0 { return "\(h)s \(m)dk" }
        return "\(m)dk"
    }
}

/// Üst çubuktaki küçük gösterge: halka + yüzde + sıfırlanmaya kalan süre.
struct PlanPill: View {
    @ObservedObject var plan: PlanStore

    var body: some View {
        let items: [(String, PlanUsage)] = [
            plan.showClaude ? plan.claude.map { ("Claude", $0) } : nil,
            plan.showCodex ? plan.codex.map { ("Codex", $0) } : nil,
        ].compactMap { $0 }
        if !items.isEmpty {
            Button {
                plan.showDetail.toggle()
            } label: {
                HStack(spacing: 8) {
                    ForEach(items, id: \.0) { name, u in
                        let w = u.dominant
                        HStack(spacing: 4) {
                            Ring(pct: w?.effectivePct ?? 0).frame(width: 11, height: 11)
                            Text(items.count > 1 ? "\(name) %\(Int(w?.effectivePct ?? 0))" : "%\(Int(w?.effectivePct ?? 0))")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            if items.count == 1, let w {
                                Text(PlanStyle.remaining(w.resetsAt)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }
                .padding(.horizontal, 8).frame(height: 22)
                .background(Capsule().fill(.white.opacity(plan.showDetail ? 0.14 : 0.06)))
            }
            .buttonStyle(.plain)
            .help("Plan kullanımı")
        }
    }
}

struct Ring: View {
    let pct: Double
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.02, pct / 100))
                .stroke(PlanStyle.color(pct), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Pill'e tıklanınca panelde açılan ayrıntı: her ajan için 5 saatlik ve haftalık pencereler.
struct PlanDetailCard: View {
    @ObservedObject var plan: PlanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plan kullanımı").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { plan.showDetail = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 12) {
                if plan.showClaude { block("Claude", plan.claude) }
                if plan.showCodex { block("Codex", plan.codex) }
            }
        }
    }

    private func block(_ name: String, _ u: PlanUsage?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 12, weight: .bold))
                if let t = u?.planType { Text(t.capitalized).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                if let c = u?.resetCredits {
                    Text("\(c) sıfırlama hakkı").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let u {
                bar("5 saatlik", u.fiveHour)
                bar("Haftalık", u.sevenDay)
                Text("Güncellendi: \(u.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            } else {
                Text(name == "Claude" ? "Claude Code'da bir istek gönderince görünür." : "Codex'e giriş yapılmamış ya da okunamadı.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.04)))
    }

    @ViewBuilder private func bar(_ title: String, _ w: PlanWindow?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let w {
                    Text("%\(Int(w.effectivePct))").font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text("· \(PlanStyle.remaining(w.resetsAt)) sonra sıfırlanır").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(PlanStyle.color(w?.effectivePct)).frame(width: g.size.width * (w?.effectivePct ?? 0) / 100)
                }
            }
            .frame(height: 6)
        }
    }
}

struct PlanSettings: View {
    @ObservedObject var plan: PlanStore
    @State private var relay = StatusLineInstaller.isInstalled()
    @State private var error: String?

    var body: some View {
        Toggle("Claude planını notch'ta göster", isOn: Binding(get: { plan.showClaude }, set: { on in
            plan.showClaude = on
            do {
                if on, !StatusLineInstaller.isInstalled() { try StatusLineInstaller.install() }
                if !on, StatusLineInstaller.isInstalled() { try StatusLineInstaller.uninstall() }
                error = nil
            } catch let e { error = e.localizedDescription }
            relay = StatusLineInstaller.isInstalled()
        }))
        Text(relay ? "Durum satırı Serçe üzerinden geçiyor; önceki durum satırın aynen çalışmaya devam ediyor."
                   : "Açınca ~/.claude/settings.json'daki statusLine Serçe'ye yönlendirilir, eski komut saklanıp çağrılır. Pro/Max planlarında çalışır.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Codex planını notch'ta göster", isOn: Binding(get: { plan.showCodex }, set: { plan.showCodex = $0 }))
            .disabled(CodexRateLimits.executable() == nil)
        Text(CodexRateLimits.executable() == nil ? "Codex CLI bulunamadı." : "Codex CLI'dan 5 dakikada bir okunur.")
            .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}

enum PlanFeatures {
    @MainActor static func register(_ app: AppState) {
        AgentRegistry.shared.add(AgentEntry(id: "plan", name: "Plan kullanımı",
                                            footer: "5 saatlik ve haftalık limitler notch'un üst çubuğunda görünür.") {
            AnyView(PlanSettings(plan: .shared))
        })
        PlanStore.shared.start()
    }
}
