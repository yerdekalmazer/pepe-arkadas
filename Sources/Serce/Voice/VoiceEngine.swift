import AVFoundation
import Speech
import SwiftUI

/// « OK Serçe » akışı: sürekli dinler, uyandırma sözünü yakalar, komutu sessizlik gelene kadar toplar,
/// Claude'a sorar, cevabı okur. Soru sorduysa uyandırma beklemeden tekrar dinler.
/// Konuşma tanıma mümkünse bu Mac'te yapılır; ses kaydı hiçbir yere gönderilmez.
@MainActor final class VoiceEngine: ObservableObject {
    static let shared = VoiceEngine()

    enum Phase: Equatable { case off, waiting, listening, thinking, speaking }

    @Published private(set) var phase: Phase = .off
    /// Dinlenen komut (canlı) ya da son soru.
    @Published private(set) var heard = ""
    /// Son cevap; notch altındaki baloncukta görünür.
    @Published private(set) var answer = ""
    @Published private(set) var error: String?

    let brain = VoiceBrain()
    private let speaker = VoiceSpeaker()
    private let audio = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Uyandırma sözünün bittiği yer; komut bundan sonrası.
    private var commandStart: String.Index?
    private var silenceWork: DispatchWorkItem?
    private var restartTimer: Timer?
    private var followUpDeadline: Date?

    var enabled: Bool { UserDefaults.standard.bool(forKey: "sesAcik") }
    var language: String { UserDefaults.standard.string(forKey: "sesDili") ?? "tr-TR" }

    // MARK: - Açma/kapama

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "sesAcik")
        on ? start() : stop()
    }

    func start() {
        guard enabled, phase == .off else { return }
        Task {
            guard await Self.authorize() else {
                error = "Mikrofon ya da konuşma tanıma izni yok. Sistem Ayarları → Gizlilik'ten aç."
                UserDefaults.standard.set(false, forKey: "sesAcik")
                return
            }
            error = nil
            phase = .waiting
            listen()
        }
    }

    func stop() {
        stopListening()
        speaker.stop()
        phase = .off
        heard = ""
    }

    /// Kısayol ve menü için: uyandırma sözü söylenmiş gibi doğrudan komut dinlemeye geç.
    func listenNow() {
        guard phase != .off else { setEnabled(true); return }
        speaker.stop()
        stopListening()
        phase = .listening
        heard = ""
        followUpDeadline = Date().addingTimeInterval(7)
        listen(wakeSatisfied: true)
    }

    static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && mic
    }

    // MARK: - Dinleme

    private func listen(wakeSatisfied: Bool = false) {
        stopListening()
        let rec = SFSpeechRecognizer(locale: Locale(identifier: language))
        guard let rec, rec.isAvailable else {
            error = "\(language) için konuşma tanıma kullanılamıyor."
            phase = .off
            return
        }
        recognizer = rec
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = false
        request = req

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        audio.prepare()
        do { try audio.start() } catch {
            self.error = "Mikrofon açılamadı: \(error.localizedDescription)"
            phase = .off
            return
        }

        commandStart = nil
        let satisfied = wakeSatisfied
        task = rec.recognitionTask(with: req) { [weak self] result, err in
            let text = result?.bestTranscription.formattedString
            let failed = err != nil
            Task { @MainActor in self?.handle(text: text, failed: failed, wakeSatisfied: satisfied) }
        }

        // Tanıma oturumları ~1 dk ile sınırlı; beklerken düzenli tazele.
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .waiting else { return }
                self.listen()
            }
        }
        if satisfied { armSilence(timeout: 7) }
    }

    private func stopListening() {
        restartTimer?.invalidate()
        silenceWork?.cancel()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
    }

    private func handle(text: String?, failed: Bool, wakeSatisfied: Bool) {
        guard phase == .waiting || phase == .listening else { return }
        guard let text else {
            if failed, phase == .waiting { listen() }
            return
        }
        if phase == .waiting, !wakeSatisfied {
            guard let end = WakePhrase.match(in: text) else { return }
            commandStart = end
            phase = .listening
            heard = ""
            NSSound(named: "Tink")?.play()
            armSilence(timeout: 6)
        }
        guard phase == .listening else { return }
        let command = commandStart.map { String(text[$0...]) } ?? text
        heard = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heard.isEmpty { armSilence(timeout: 1.3) }
    }

    /// Konuşma bu kadar süre durursa komut bitmiş sayılır.
    private func armSilence(timeout: TimeInterval) {
        silenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.commandEnded() }
        }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func commandEnded() {
        guard phase == .listening else { return }
        let command = heard
        stopListening()
        guard !command.isEmpty else {
            phase = .waiting
            listen()
            return
        }
        Task { await respond(to: command) }
    }

    // MARK: - Cevap

    private func respond(to command: String) async {
        phase = .thinking
        answer = ""
        do {
            answer = try await brain.ask(command)
        } catch {
            answer = error.localizedDescription
        }
        phase = .speaking
        await speaker.speak(answer, language: language)
        guard enabled, phase == .speaking else { return }
        if brain.expectsReply {
            phase = .listening
            heard = ""
            listen(wakeSatisfied: true)
        } else {
            phase = .waiting
            listen()
        }
    }

    /// Ayarlardaki "Dene" düğmesi.
    func preview() {
        Task { await speaker.speak(language.hasPrefix("tr") ? "Merhaba, ben Serçe. Seni dinliyorum." : "Hi, I'm Serçe. I'm listening.",
                                   language: language) }
    }
}

/// Uyandırma sözü eşleme: « OK Serçe », « Okey Serçe », « Hey Serçe » ve tanıyıcının sık yanlış yazdığı biçimler.
enum WakePhrase {
    static let names = ["serçe", "serce", "sersey", "serje", "sercé"]
    static let openers = ["ok", "okey", "okay", "o.k.", "hey", "hay", "selam"]

    /// Eşleşirse sözün bittiği konumu döner.
    static func match(in text: String) -> String.Index? {
        let lower = text.lowercased()
        for name in names {
            var search = lower.startIndex..<lower.endIndex
            while let r = lower.range(of: name, range: search) {
                let before = lower[lower.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespacesAndPunctuation)
                if openers.contains(where: { before.hasSuffix($0) }) {
                    var end = r.upperBound
                    // "Serçe," gibi noktalamayı da yut.
                    while end < lower.endIndex, lower[end].isPunctuation || lower[end] == " " { end = lower.index(after: end) }
                    return text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: end))
                }
                search = r.upperBound..<lower.endIndex
            }
        }
        return nil
    }
}

private extension CharacterSet {
    static let whitespacesAndPunctuation = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
}

private extension String {
    func trimmingCharacters(in set: CharacterSet) -> String {
        (self as NSString).trimmingCharacters(in: set)
    }
}
