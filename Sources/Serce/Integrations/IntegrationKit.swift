import AppKit
import SwiftUI

// MARK: - Ağ

enum HTTPError: LocalizedError {
    case status(Int)
    case badBody
    var errorDescription: String? {
        switch self {
        case .status(let c): c == 401 || c == 403 ? "Anahtar geçersiz" : "Sunucu \(c) döndü"
        case .badBody: "Beklenmeyen yanıt"
        }
    }
}

/// Entegrasyonların ortak JSON istemcisi. Yalnızca kullanıcının anahtarını girdiği servislere gider.
enum HTTP {
    static func json(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Any? = nil) async throws -> Any {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Serce/0.2", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HTTPError.status(code) }
        return try JSONSerialization.jsonObject(with: data)
    }
}

/// Gevşek JSON erişimi: eksik alan çökertmez, boş değer döner.
extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue }
    func double(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func dict(_ k: String) -> [String: Any] { self[k] as? [String: Any] ?? [:] }
    func arr(_ k: String) -> [[String: Any]] { self[k] as? [[String: Any]] ?? [] }
}

// MARK: - Tarih ve sayı biçimleri

enum Fmt {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// ISO 8601 (kesirli ya da değil) ve Resend'in "2026-04-03 22:13:42.674981+00" biçimini okur.
    static func date(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let d = iso.date(from: s) ?? isoPlain.date(from: s) { return d }
        // Resend: boşluk ayraçlı, mikro saniyeli, "+00" bölgeli
        s = s.replacingOccurrences(of: " ", with: "T")
        if s.hasSuffix("+00") { s += ":00" }
        if let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = s[s.index(after: dot)..<tz].prefix(3)
            s = String(s[..<dot]) + "." + frac + String(s[tz...])
        }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    static func relative(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "" }
        let s = now.timeIntervalSince(d)
        if s < 0 {
            let f = -s
            if f < 3600 { return "\(max(1, Int(f / 60))) dk sonra" }
            if f < 86400 { return "\(Int(f / 3600)) sa sonra" }
            return "\(Int(f / 86400)) g sonra"
        }
        if s < 60 { return "şimdi" }
        if s < 3600 { return "\(Int(s / 60)) dk" }
        if s < 86400 { return "\(Int(s / 3600)) sa" }
        return "\(Int(s / 86400)) g"
    }

    /// Sesli özet için: "az önce", "5 dk önce".
    static func ago(_ d: Date?) -> String {
        let r = relative(d)
        return r == "şimdi" ? "az önce" : (r.hasSuffix("sonra") || r.isEmpty ? r : r + " önce")
    }

    static func clock(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func dayWord(_ d: Date?) -> String {
        guard let d else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "bugün" }
        if cal.isDateInTomorrow(d) { return "yarın" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMM EEE"
        return f.string(from: d)
    }

    static func number(_ v: Double, decimals: Int = 2) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.numberStyle = .decimal
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func currencySymbol(_ code: String) -> String {
        switch code.uppercased() {
        case "EUR": "€"
        case "USD": "$"
        case "GBP": "£"
        case "TRY": "₺"
        default: code.uppercased()
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Yoklayan pill tabanı

enum FetchStatus: Equatable {
    case idle, loading, ok, failed(String)
}

/// Aktifken her 60 sn veri çeken pill'lerin ortak tabanı. Alt sınıf `fetch()` ve `configured` sağlar.
@MainActor class PollingPill<Model>: ObservableObject {
    @Published var model: Model?
    @Published var status: FetchStatus = .idle
    @Published var updated: Date?
    /// Snapshot modunda ağ kapalı; veri elle verilir.
    var frozen = false
    var interval: TimeInterval { 60 }
    var configured: Bool { true }

    private var timer: Timer?
    private var task: Task<Void, Never>?

    func fetch() async throws -> Model { throw HTTPError.badBody }

    func start() {
        guard !frozen, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    func refresh() {
        guard !frozen else { return }
        guard configured else { status = .idle; model = nil; return }
        task?.cancel()
        if model == nil { status = .loading }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let m = try await self.fetch()
                if Task.isCancelled { return }
                self.model = m
                self.status = .ok
                self.updated = Date()
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                self.status = .failed((error as? LocalizedError)?.errorDescription ?? "Bağlanamadı")
            }
        }
    }

    /// Snapshot için örnek veri yükle.
    func freeze(with m: Model) {
        frozen = true
        model = m
        status = .ok
        updated = Date()
    }
}

// MARK: - Kart parçaları

/// Coucou'nun servis kartı düzeni: solda pill renginde kuş, sağda başlık + içerik.
struct IntegrationFrame<M, Content: View>: View {
    @ObservedObject var pill: PollingPill<M>
    let title: String
    let subtitle: String
    let color: Color
    var attention: (M) -> Bool = { _ in false }
    @ViewBuilder let content: (M) -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Bird(mood: mood, size: 52, tint: color)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 6, height: 6)
                    Text(title).font(.system(size: 12, weight: .bold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let u = pill.updated, pill.status == .ok {
                        Text(Fmt.relative(u)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                switch pill.status {
                case .idle where !pill.configured:
                    SetupHint()
                case .failed(let why) where pill.model == nil:
                    Text("Bağlanamadı · \(why)").font(.system(size: 11)).foregroundStyle(.secondary)
                case _ where pill.model == nil:
                    HStack(spacing: 6) {
                        Spinner().frame(width: 10, height: 10)
                        Text("Yükleniyor…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                default:
                    if let m = pill.model { content(m) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.035)))
    }

    private var isAlert: Bool { pill.model.map(attention) ?? false }

    private var mood: Mood {
        if isAlert { return .alert }
        if case .failed = pill.status { return .idle }
        return pill.model == nil ? .sleep : .idle
    }

    private var dot: Color {
        if isAlert { return Palette.amber }
        if case .failed = pill.status { return .gray }
        return color
    }
}

struct SetupHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Anahtar gerekli").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Ayarlar") { SettingsWindowController.shared.show(section: "pilller") }
                .buttonStyle(Pill(kind: .quiet))
        }
    }
}

/// Büyük değer satırı: "1.284,50 €" ve yanında küçük birim/açıklama.
struct BigValue: View {
    let value: String
    var unit: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            if !unit.isEmpty { Text(unit).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// Listedeki tek satır: durum noktası, başlık, sağda değer ve zaman. Tıklayınca bağlantıyı açar.
struct ServiceRow: View {
    var dot: Color = .gray
    let title: String
    var detail: String = ""
    var value: String = ""
    var valueColor: Color = .white.opacity(0.85)
    var time: String = ""
    var link: URL? = nil
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 5, height: 5)
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if !value.isEmpty {
                Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(valueColor).lineLimit(1)
            }
            if !time.isEmpty {
                Text(time).font(.system(size: 9)).foregroundStyle(.tertiary).frame(minWidth: 24, alignment: .trailing)
            }
        }
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(hover && link != nil ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let link { NSWorkspace.shared.open(link) } }
    }
}

struct EmptyLine: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 11)).foregroundStyle(.tertiary) }
}

/// Ayarlardaki düz (gizli olmayan) metin alanı; UserDefaults'ta saklanır.
struct PlainSettingField: View {
    let title: String
    let key: String
    var placeholder = ""
    var onChange: () -> Void = {}
    @State private var value = ""

    var body: some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Button("Kaydet", action: save)
        }
        .onAppear { value = UserDefaults.standard.string(forKey: key) ?? "" }
    }

    private func save() {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
        onChange()
    }
}
