import Foundation

/// Claude çağrılarının token ve tahmini maliyet sayacı. Günlük toplamlar Application Support/Serce/kullanim.json'da.
/// Arka plan işleri (proje hafızası özetleri) günlük bütçeyi aşınca durur.
@MainActor final class UsageMeter: ObservableObject {
    static let shared = UsageMeter()

    enum Purpose: String, CaseIterable, Codable {
        case chat = "Sohbet", voice = "Ses", memory = "Proje hafızası", agent = "Arka plan ajanı"
    }

    struct Totals: Codable {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        var cost = 0.0
        var calls = 0
    }

    /// gün ("2026-10-12") → amaç → toplam
    @Published private(set) var days: [String: [String: Totals]] = [:]

    private var url: URL { Support.dir.appendingPathComponent("kullanim.json") }

    init() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([String: [String: Totals]].self, from: d) {
            days = v
        }
    }

    /// Günlük arka plan bütçesi (USD). 0 = arka plan özetleri kapalı.
    var backgroundBudget: Double {
        get { UserDefaults.standard.object(forKey: "arkaPlanButce") as? Double ?? 0.10 }
        set { UserDefaults.standard.set(newValue, forKey: "arkaPlanButce"); objectWillChange.send() }
    }

    var canSpendBackground: Bool { today[Purpose.memory.rawValue, default: Totals()].cost < backgroundBudget }

    var today: [String: Totals] { days[Self.dayKey(Date())] ?? [:] }

    func todayTotal() -> Totals {
        today.values.reduce(into: Totals()) { a, t in
            a.input += t.input; a.output += t.output; a.cacheRead += t.cacheRead; a.cacheWrite += t.cacheWrite
            a.cost += t.cost; a.calls += t.calls
        }
    }

    /// Messages API `usage` nesnesini kaydeder.
    func record(model: String, usage: [String: Any]?, purpose: Purpose) {
        guard let u = usage else { return }
        record(model: model, input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
               cacheRead: u["cache_read_input_tokens"] as? Int ?? 0, cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
               purpose: purpose)
    }

    /// Claude Code'un kendi raporladığı maliyet (Serçe'nin başlattığı terminalsiz oturumlar).
    func recordCost(_ cost: Double, purpose: Purpose) {
        let day = Self.dayKey(Date())
        var t = days[day]?[purpose.rawValue] ?? Totals()
        t.cost += cost
        t.calls += 1
        days[day, default: [:]][purpose.rawValue] = t
        if let d = try? JSONEncoder().encode(days) { try? d.write(to: url, options: .atomic) }
    }

    func record(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, purpose: Purpose) {
        let p = Self.price(model)
        let cost = (Double(input) * p.input + Double(output) * p.output
                    + Double(cacheRead) * p.cacheRead + Double(cacheWrite) * p.cacheWrite) / 1_000_000
        let day = Self.dayKey(Date())
        var t = days[day]?[purpose.rawValue] ?? Totals()
        t.input += input; t.output += output; t.cacheRead += cacheRead; t.cacheWrite += cacheWrite
        t.cost += cost; t.calls += 1
        days[day, default: [:]][purpose.rawValue] = t
        // Yalnızca son 60 gün tutulur.
        if days.count > 60, let oldest = days.keys.sorted().first { days.removeValue(forKey: oldest) }
        if let d = try? JSONEncoder().encode(days) { try? d.write(to: url, options: .atomic) }
    }

    /// 1M token başına USD (giriş, çıkış, önbellek okuma, önbellek yazma). Tahmindir.
    static func price(_ model: String) -> (input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        if model.contains("haiku") { return (0.10, 0.50, 0.01, 0.125) }
        if model.contains("sonnet") { return (2, 10, 0.20, 2.5) }
        if model.contains("fable") { return (10, 50, 0.25, 12.5) }
        return (4, 20, 0.20, 5)
    }

    nonisolated static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
