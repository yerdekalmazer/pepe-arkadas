import AVFoundation
import Speech

/// Sohbet alanına dikte. Tanıma mümkünse cihaz üstünde yapılır; izin yalnızca düğmeye basınca istenir.
@MainActor final class Dictation: ObservableObject {
    static let shared = Dictation()

    static let languages: [(id: String, title: String)] = [
        ("tr-TR", "Türkçe"), ("en-US", "English (US)"), ("en-GB", "English (UK)"),
        ("de-DE", "Deutsch"), ("fr-FR", "Français"), ("es-ES", "Español"),
    ]

    @Published private(set) var listening = false
    @Published private(set) var error: String?
    var language: String {
        get { UserDefaults.standard.string(forKey: "dikteDili") ?? "tr-TR" }
        set { UserDefaults.standard.set(newValue, forKey: "dikteDili"); objectWillChange.send() }
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Dinlemeyi başlatır; her ara sonuçta `onText(tümMetin)` çağrılır.
    func toggle(onText: @escaping (String) -> Void) {
        if listening { stop(); return }
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.error = "Konuşma tanıma izni verilmedi."; return }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    Task { @MainActor in
                        if ok { self.start(onText: onText) } else { self.error = "Mikrofon izni verilmedi." }
                    }
                }
            }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
    }

    private func start(onText: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            error = "Bu dil için tanıma kullanılamıyor."
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            self.error = "Mikrofon başlatılamadı."
            input.removeTap(onBus: 0)
            return
        }
        listening = true
        task = recognizer.recognitionTask(with: req) { result, err in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                if let text { onText(text) }
                if err != nil || final { self.stop() }
            }
        }
    }
}
