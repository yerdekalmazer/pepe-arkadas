import AppKit
import AVFoundation

/// Pepe'nin sesleri: hepsi açılışta matematikle üretilir (ses dosyası yok).
/// ~/Library/Application Support/Serce/Sesler/<anahtar>.wav|.mp3|.aiff|.m4a varsa onun yerine o çalar.
@MainActor final class SoundEngine {
    static let shared = SoundEngine()

    enum Cue: String, CaseIterable {
        case chirp, approval, done, poke, dizzy, greet, drop, error, pop, whoosh

        var title: String {
            switch self {
            case .chirp: "Havlama"
            case .approval: "İzin isteği"
            case .done: "İş bitti"
            case .poke: "Dürtme"
            case .dizzy: "Baş dönmesi"
            case .greet: "Selam"
            case .drop: "Dosya bırakma"
            case .error: "Hata"
            case .pop: "Bildirim"
            case .whoosh: "Fırlayış"
            }
        }
    }

    static var folder: URL { Support.dir.appendingPathComponent("Sesler", isDirectory: true) }

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var overrides: [Cue: NSSound] = [:]

    private var enabled: Bool { !UserDefaults.standard.bool(forKey: "sesKapali") }

    func prepareFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    }

    /// `force` ayarlar penceresindeki önizleme içindir; ses kapalı olsa da çalar.
    func play(_ cue: Cue, force: Bool = false) {
        guard enabled || force else { return }
        if let custom = override(cue) {
            custom.stop()
            custom.play()
            return
        }
        guard start(), let buffer = buffer(cue) else { return }
        let p = players[next]
        next = (next + 1) % players.count
        p.stop()
        p.scheduleBuffer(buffer, at: nil, options: [])
        p.play()
    }

    private func override(_ cue: Cue) -> NSSound? {
        for ext in ["wav", "mp3", "aiff", "m4a", "caf"] {
            let url = Self.folder.appendingPathComponent("\(cue.rawValue).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return NSSound(contentsOf: url, byReference: true) }
        }
        return nil
    }

    private func start() -> Bool {
        if players.isEmpty {
            for _ in 0..<4 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: format)
                players.append(p)
            }
            engine.mainMixerNode.outputVolume = 0.55
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        return true
    }

    private func buffer(_ cue: Cue) -> AVAudioPCMBuffer? {
        if let b = buffers[cue] { return b }
        let samples = Synth.render(cue)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            b.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        buffers[cue] = b
        return b
    }
}

/// Küçük bir sentezleyici: frekans kaymalı sinüsler, zarf ve biraz gürültü.
enum Synth {
    static let rate = 44_100.0

    /// Bir "nota": başlangıç/bitiş frekansı, süre, gecikme, ses düzeyi, titreşim, harmonik.
    struct Note {
        var f0: Double, f1: Double, dur: Double, at: Double = 0, amp: Double = 0.5
        var vibrato: Double = 0, harmonic: Double = 0, noise: Double = 0
    }

    static func render(_ cue: SoundEngine.Cue) -> [Float] {
        switch cue {
        case .chirp:
            // Küçük bir "hav": hızlı yükselip düşen, gürültülü, harmonikli kısa ses.
            return mix([Note(f0: 560, f1: 900, dur: 0.045, amp: 0.45, harmonic: 0.8, noise: 0.12),
                         Note(f0: 900, f1: 480, dur: 0.09, at: 0.04, amp: 0.45, harmonic: 0.8, noise: 0.12)])
        case .approval:
            return mix([Note(f0: 880, f1: 880, dur: 0.16, amp: 0.4, harmonic: 0.3),
                        Note(f0: 1320, f1: 1320, dur: 0.22, at: 0.12, amp: 0.4, harmonic: 0.3)])
        case .done:
            return mix([Note(f0: 1047, f1: 1047, dur: 0.14, amp: 0.32, harmonic: 0.2),
                        Note(f0: 1319, f1: 1319, dur: 0.14, at: 0.10, amp: 0.32, harmonic: 0.2),
                        Note(f0: 1568, f1: 1568, dur: 0.30, at: 0.20, amp: 0.34, harmonic: 0.2)])
        case .poke:
            return mix([Note(f0: 340, f1: 200, dur: 0.09, amp: 0.5, noise: 0.15),
                        Note(f0: 1900, f1: 1500, dur: 0.05, at: 0.06, amp: 0.2)])
        case .dizzy:
            return mix([Note(f0: 1300, f1: 380, dur: 0.65, amp: 0.35, vibrato: 0.08)])
        case .greet:
            // "Hav hav!"
            return mix([Note(f0: 600, f1: 980, dur: 0.045, amp: 0.42, harmonic: 0.8, noise: 0.1),
                        Note(f0: 980, f1: 520, dur: 0.09, at: 0.04, amp: 0.42, harmonic: 0.8, noise: 0.1),
                        Note(f0: 660, f1: 1080, dur: 0.045, at: 0.22, amp: 0.45, harmonic: 0.8, noise: 0.1),
                        Note(f0: 1080, f1: 560, dur: 0.11, at: 0.26, amp: 0.45, harmonic: 0.8, noise: 0.1)])
        case .drop:
            return mix([Note(f0: 700, f1: 140, dur: 0.12, amp: 0.55)])
        case .error:
            return mix([Note(f0: 220, f1: 210, dur: 0.12, amp: 0.35, harmonic: 0.6),
                        Note(f0: 196, f1: 180, dur: 0.18, at: 0.16, amp: 0.35, harmonic: 0.6)])
        case .pop:
            return mix([Note(f0: 900, f1: 1500, dur: 0.07, amp: 0.45)])
        case .whoosh:
            return mix([Note(f0: 300, f1: 900, dur: 0.35, amp: 0.25, noise: 0.9)])
        }
    }

    private static func mix(_ notes: [Note]) -> [Float] {
        let total = notes.map { $0.at + $0.dur }.max() ?? 0
        var out = [Float](repeating: 0, count: Int((total + 0.02) * rate))
        var seed: UInt32 = 12345
        for n in notes {
            let start = Int(n.at * rate), count = Int(n.dur * rate)
            var phase = 0.0
            for i in 0..<count where start + i < out.count {
                let p = Double(i) / Double(count)
                // Üstel frekans kayması daha "kuş gibi" duyulur.
                var f = n.f0 * pow(n.f1 / n.f0, p)
                if n.vibrato > 0 { f *= 1 + n.vibrato * sin(Double(i) / rate * 2 * .pi * 9) }
                phase += 2 * .pi * f / rate
                var v = sin(phase) + n.harmonic * sin(phase * 2) * 0.5
                if n.noise > 0 {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    v = v * (1 - n.noise) + (Double(seed) / Double(UInt32.max) * 2 - 1) * n.noise
                }
                // Hızlı atak, yumuşak sönüm.
                let env = min(1, p * 30) * pow(1 - p, 1.6)
                out[start + i] += Float(v * env * n.amp)
            }
        }
        return out.map { max(-1, min(1, $0)) }
    }
}
