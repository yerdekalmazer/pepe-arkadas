import AVFoundation

/// Pepe'nin sesi: Mac'in sesleri (kadın/erkek, perde, en kaliteli yüklü ses) ya da kullanıcının ElevenLabs anahtarı.
@MainActor final class VoiceSpeaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var finish: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking || (player?.isPlaying ?? false) }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        resume()
    }

    func speak(_ text: String, language: String) async {
        stop()
        let d = UserDefaults.standard
        if d.bool(forKey: "elevenlabsAcik"), let key = Keychain.get("elevenlabs"),
           let audio = await elevenLabs(text, key: key, voice: d.string(forKey: "elevenlabsSes") ?? "") {
            await play(audio)
            return
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestVoice(language: language, female: d.object(forKey: "sesKadin") as? Bool ?? true)
        u.pitchMultiplier = Float(d.object(forKey: "sesPerde") as? Double ?? 1.1)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        await withCheckedContinuation { c in
            finish = c
            synth.speak(u)
        }
    }

    /// İstenen dildeki en kaliteli ses (Premium > Gelişmiş > Varsayılan), mümkünse istenen cinsiyette.
    static func bestVoice(language: String, female: Bool) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let gender: AVSpeechSynthesisVoiceGender = female ? .female : .male
        let ranked = voices.sorted { a, b in
            let ga = a.gender == gender ? 1 : 0, gb = b.gender == gender ? 1 : 0
            if ga != gb { return ga > gb }
            return a.quality.rawValue > b.quality.rawValue
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: language)
    }

    private func elevenLabs(_ text: String, key: String, voice: String) async -> Data? {
        let id = voice.isEmpty ? "21m00Tcm4TlvDq8ikWAM" : voice
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(id)?output_format=mp3_44100_128") else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue(key, forHTTPHeaderField: "xi-api-key")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": "eleven_multilingual_v2"])
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func play(_ data: Data) async {
        guard let p = try? AVAudioPlayer(data: data) else { return }
        player = p
        p.delegate = self
        await withCheckedContinuation { c in
            finish = c
            p.play()
        }
    }

    private func resume() {
        finish?.resume()
        finish = nil
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.resume() }
    }
}
