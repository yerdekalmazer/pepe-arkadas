import AppKit
import SwiftUI

/// Bir müzik çalarının anlık durumu. AppleScript çıktısından ayrıştırılır.
struct NowPlaying: Equatable {
    enum Repeat: Equatable { case off, all, one }
    var title = ""
    var artist = ""
    var album = ""
    /// Saniye.
    var duration: Double = 0
    /// Saniye; `fetchedAt` anındaki konum.
    var position: Double = 0
    var playing = false
    var shuffle = false
    var repeatMode: Repeat = .off
    /// 0–100
    var volume: Double = 50
    var artworkURL: URL?
    var fetchedAt = Date()

    /// Çalarken yoklamalar arasında konumu tahmin eder.
    func position(at date: Date) -> Double {
        guard playing else { return position }
        return min(duration, position + date.timeIntervalSince(fetchedAt))
    }

    var trackKey: String { title + "|" + artist + "|" + album }
}

/// Desteklenen çalarlar ve AppleScript sözlükleri arasındaki farklar.
enum MusicApp {
    case spotify, music

    var bundleId: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var name: String { self == .spotify ? "Spotify" : "Apple Music" }
    static let separator = "‖"

    /// Durum betiği: alanlar `‖` ile ayrılır. Çalmıyorsa yalnızca "stopped".
    var statusScript: String {
        let sep = Self.separator
        switch self {
        case .spotify:
            return """
            tell application id "com.spotify.client"
              set st to player state as string
              if st is "stopped" then return "stopped"
              set t to current track
              return st & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & ((duration of t) as string) & "\(sep)" & ((player position) as string) & "\(sep)" & (shuffling as string) & "\(sep)" & (repeating as string) & "\(sep)" & (sound volume as string) & "\(sep)" & (artwork url of t)
            end tell
            """
        case .music:
            return """
            tell application id "com.apple.Music"
              set st to player state as string
              if st is "stopped" then return "stopped"
              set t to current track
              return st & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & ((duration of t) as string) & "\(sep)" & ((player position) as string) & "\(sep)" & (shuffle enabled as string) & "\(sep)" & (song repeat as string) & "\(sep)" & (sound volume as string) & "\(sep)"
            end tell
            """
        }
    }

    /// Apple Music kapağı ayrı istenir (yalnızca parça değişince); ham veri döner.
    var artworkScript: String? {
        self == .music ? #"tell application id "com.apple.Music" to get raw data of artwork 1 of current track"# : nil
    }

    /// Durum betiği çıktısını ayrıştırır. "stopped" ya da bozuk çıktı için nil.
    static func parse(_ raw: String, app: MusicApp, now: Date = Date()) -> NowPlaying? {
        let f = raw.components(separatedBy: separator)
        guard f.count >= 9 else { return nil }
        func num(_ s: String) -> Double { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0 }
        var p = NowPlaying()
        p.playing = f[0] == "playing"
        p.title = f[1]
        p.artist = f[2]
        p.album = f[3]
        // Spotify süreyi milisaniye, Apple Music saniye verir.
        p.duration = app == .spotify ? num(f[4]) / 1000 : num(f[4])
        p.position = num(f[5])
        p.shuffle = f[6] == "true"
        switch (app, f[7]) {
        case (.spotify, "true"), (.music, "all"): p.repeatMode = .all
        case (.music, "one"): p.repeatMode = .one
        default: p.repeatMode = .off
        }
        p.volume = num(f[8])
        if f.count > 9, !f[9].isEmpty { p.artworkURL = URL(string: f[9]) }
        p.fetchedAt = now
        return p
    }

    /// AppleScript dizgesi içine güvenle konacak metin.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Başarılıysa "ok" döner.
    static func playScript(_ app: MusicApp, query: String) -> String {
        let q = quoted(query)
        switch app {
        case .spotify:
            return """
            tell application id "com.spotify.client"
              play track "spotify:search:" & \(q)
              delay 1
              if player state is playing then return "ok"
              return "yok"
            end tell
            """
        case .music:
            return """
            tell application id "com.apple.Music"
              set r to (every track of library playlist 1 whose name contains \(q) or artist contains \(q) or album contains \(q))
              if r is {} then return "yok"
              play item 1 of r
              return "ok"
            end tell
            """
        }
    }

    // MARK: Komutlar

    func command(_ c: MusicCommand) -> String {
        let target = "tell application id \"\(bundleId)\" to "
        switch c {
        case .playPause: return target + "playpause"
        case .next: return target + "next track"
        case .previous: return target + "previous track"
        case .seek(let s): return target + "set player position to \(String(format: "%.2f", s))"
        case .volume(let v): return target + "set sound volume to \(Int(v.rounded()))"
        case .shuffle(let on):
            return target + (self == .spotify ? "set shuffling to \(on)" : "set shuffle enabled to \(on)")
        case .repeatMode(let r):
            if self == .spotify { return target + "set repeating to \(r != .off)" }
            return target + "set song repeat to " + (r == .off ? "off" : (r == .one ? "one" : "all"))
        }
    }
}

enum MusicCommand {
    case playPause, next, previous
    case seek(Double)
    case volume(Double)
    case shuffle(Bool)
    case repeatMode(NowPlaying.Repeat)
}

/// Tüm AppleScript'ler tek seri kuyrukta, ana iş parçacığı dışında koşar.
enum ScriptRunner {
    static let queue = DispatchQueue(label: "serce.muzik.applescript")

    /// Dize sonucu döner; hata varsa nil.
    static func string(_ source: String) -> String? {
        var err: NSDictionary?
        let d = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil ? d?.stringValue : nil
    }

    static func data(_ source: String) -> Data? {
        var err: NSDictionary?
        let d = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil ? d?.data : nil
    }
}

/// Bir müzik çaları notch pill'i olarak sunar. Yalnızca pill açıkken ve uygulama çalışıyorken yoklar;
/// uygulamayı asla kendiliğinden başlatmaz.
@MainActor final class MusicController: ObservableObject, PillProvider {
    static var all: [MusicController] = []

    let app: MusicApp
    @Published private(set) var now: NowPlaying?
    @Published private(set) var running = false
    @Published private(set) var artwork: NSImage?

    private var timer: Timer?
    private var inFlight = false
    private var artworkKey = ""
    /// Komut sonrası kısa süre yoklama sonucunu yok say; iyimser güncelleme geri zıplamasın.
    private var holdUntil = Date.distantPast

    init(_ app: MusicApp) {
        self.app = app
        Self.all.append(self)
    }

    // MARK: PillProvider

    var id: String { app == .spotify ? "spotify" : "apple-music" }
    var title: String { app.name }
    var subtitle: String {
        guard running else { return "Kapalı" }
        guard let now else { return "Boşta" }
        return now.playing ? "Çalıyor" : "Duraklatıldı"
    }
    var color: Color {
        app == .spotify ? Color(red: 0.12, green: 0.84, blue: 0.38) : Color(red: 0.98, green: 0.24, blue: 0.35)
    }
    var isConfigured: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) != nil }

    func card() -> AnyView { AnyView(MusicCard(controller: self)) }

    func settings() -> AnyView? {
        AnyView(Text("İlk kullanımda macOS, Pepe'nin \(app.name)'i kontrol etmesine izin vermeni ister. \(app.name) kapalıyken Pepe onu açmaz ve yoklamaz.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true))
    }

    func start() {
        guard timer == nil else { return }
        poll()
        // İlerleme çubuğu konumu yerelde hesaplar; yoklama yalnızca parça/durum değişikliği için, seyrek yeterli.
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        now = nil
        Self.updatePlayingFlag()
    }

    // MARK: Yoklama

    private func poll() {
        running = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId).isEmpty
        guard running else {
            if now != nil { now = nil; Self.updatePlayingFlag() }
            return
        }
        guard !inFlight else { return }
        inFlight = true
        let script = app.statusScript, app = self.app
        ScriptRunner.queue.async { [weak self] in
            let raw = ScriptRunner.string(script)
            let parsed = raw.flatMap { MusicApp.parse($0, app: app) }
            Task { @MainActor in
                guard let self else { return }
                self.inFlight = false
                if Date() < self.holdUntil { return }
                self.apply(parsed)
            }
        }
    }

    private func apply(_ p: NowPlaying?) {
        if p != now { now = p }
        Self.updatePlayingFlag()
        guard let p, p.trackKey != artworkKey else { return }
        artworkKey = p.trackKey
        artwork = nil
        loadArtwork(p)
    }

    private func loadArtwork(_ p: NowPlaying) {
        let key = p.trackKey
        if let url = p.artworkURL {
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) else { return }
                if self?.artworkKey == key { self?.artwork = img }
            }
        } else if let script = app.artworkScript {
            ScriptRunner.queue.async { [weak self] in
                let img = ScriptRunner.data(script).flatMap(NSImage.init(data:))
                Task { @MainActor in if self?.artworkKey == key { self?.artwork = img } }
            }
        }
    }

    // MARK: Komutlar

    func send(_ c: MusicCommand) {
        // İyimser güncelleme: arayüz anında tepki versin, sonraki yokla düzeltir.
        if var n = now {
            switch c {
            case .playPause: n.position = n.position(at: Date()); n.playing.toggle()
            case .seek(let s): n.position = s
            case .volume(let v): n.volume = v
            case .shuffle(let on): n.shuffle = on
            case .repeatMode(let r): n.repeatMode = r
            case .next, .previous: n.position = 0
            }
            n.fetchedAt = Date()
            now = n
            Self.updatePlayingFlag()
        }
        holdUntil = Date().addingTimeInterval(0.8)
        let script = app.command(c)
        ScriptRunner.queue.async { [weak self] in
            _ = ScriptRunner.string(script)
            Task { @MainActor in
                guard let self else { return }
                self.holdUntil = .distantPast
                self.poll()
            }
        }
    }

    // MARK: Dış API (sesli asistan, kısayollar)

    /// Sesli asistanın okuyacağı tek cümlelik durum.
    var voiceSummary: String {
        guard running else { return "\(app.name) kapalı." }
        guard let now, !now.title.isEmpty else { return "\(app.name) açık ama bir şey çalmıyor." }
        let who = now.artist.isEmpty ? now.title : "\(now.artist) — \(now.title)"
        return now.playing ? "\(app.name)'da \(who) çalıyor." : "\(app.name)'da \(who) duraklatıldı."
    }

    func playPause() { send(.playPause) }
    func next() { send(.next) }
    func previous() { send(.previous) }
    func setVolume(_ v: Double) { send(.volume(max(0, min(100, v)))) }

    /// Aramayla çal. Uygulama kapalıysa açılabilir (yalnızca bu çağrıda).
    /// Spotify: arama URI'sini çalmayı dener, olmazsa Spotify'da aramayı açar. Music: kütüphanede ilk eşleşen parça.
    func play(query: String) async -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        let script = MusicApp.playScript(app, query: q)
        let ok: Bool = await withCheckedContinuation { cont in
            ScriptRunner.queue.async { cont.resume(returning: ScriptRunner.string(script) == "ok") }
        }
        if !ok, app == .spotify,
           let url = URL(string: "spotify:search:" + (q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q)) {
            NSWorkspace.shared.open(url)
            start()
            return true
        }
        if ok { start(); poll() }
        return ok
    }

    func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Sahte durum (yalnızca anlık görüntü için).
    func preview(_ p: NowPlaying?, running: Bool = true, artwork: NSImage? = nil) {
        self.running = running
        self.now = p
        self.artwork = artwork
    }

    static func updatePlayingFlag() {
        let playing = all.contains { $0.now?.playing == true }
        if AppState.shared.musicPlaying != playing { AppState.shared.musicPlaying = playing }
    }
}
