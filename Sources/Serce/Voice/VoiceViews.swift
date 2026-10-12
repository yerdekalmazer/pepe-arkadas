import AppKit
import SwiftUI

/// Notch'un altında sesli konuşmanın durumu: dinliyor / düşünüyor / konuşuyor + metin.
struct VoiceCaption: View {
    @ObservedObject var engine: VoiceEngine
    @State private var expanded = false

    var body: some View {
        if visible {
            HStack(alignment: .top, spacing: 8) {
                icon.frame(width: 16, height: 16)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(expanded ? 12 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Capsule(style: .continuous).fill(.black).opacity(expanded ? 0 : 1))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black).opacity(expanded ? 1 : 0))
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            .transition(.opacity.combined(with: .move(edge: .top)))
            .environment(\.colorScheme, .dark)
        }
    }

    private var visible: Bool {
        switch engine.phase {
        case .off: false
        case .waiting: !engine.answer.isEmpty && expanded
        default: true
        }
    }

    private var text: String {
        switch engine.phase {
        case .listening: engine.heard.isEmpty ? "Dinliyorum…" : engine.heard
        case .thinking: engine.heard.isEmpty ? "Düşünüyorum…" : "“\(engine.heard)”"
        case .speaking, .waiting: engine.answer
        case .off: ""
        }
    }

    @ViewBuilder private var icon: some View {
        switch engine.phase {
        case .listening:
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(Palette.blue)
                            .frame(width: 2.5, height: 4 + 9 * abs(sin(t * 6 + Double(i))))
                    }
                }
            }
        case .thinking: Spinner().frame(width: 11, height: 11)
        default: Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(Palette.green)
        }
    }
}

struct VoiceSettings: View {
    @ObservedObject var engine: VoiceEngine
    @AppStorage("sesAcik") private var on = false
    @AppStorage("sesDili") private var language = "tr-TR"
    @AppStorage("sesKadin") private var female = true
    @AppStorage("sesPerde") private var pitch = 1.1
    @AppStorage("sesModeli") private var model = "claude-opus-5-5"
    @AppStorage("elevenlabsAcik") private var eleven = false
    @AppStorage("elevenlabsSes") private var elevenVoice = ""

    var body: some View {
        SettingsGroup(title: "« OK Serçe »",
                      footer: "« OK Serçe » de, sonra sor: « Stripe'ta bugün ne kazandım? », « GitHub yerine Stripe koy », « biraz Daft Punk çal », « Enzo'ya görselin hazır olduğunu yaz ». Konuşma tanıma mümkünse bu Mac'te yapılır; Anthropic'e ses değil, yalnızca söylediğin cümle ve cevap için okunan veri gider. E-postalar taslak olarak açılır, sen Gönder'e basmadan gitmez.") {
            Toggle("Sesli asistan açık", isOn: Binding(get: { on }, set: { engine.setEnabled($0); on = engine.enabled }))
            Picker("Dil", selection: $language) {
                Text("Türkçe").tag("tr-TR")
                Text("English").tag("en-US")
            }
            .onChange(of: language) { if on { engine.stop(); engine.start() } }
            Picker("Akıl", selection: $model) {
                ForEach(VoiceBrain.models, id: \.id) { Text($0.name).tag($0.id) }
            }
            if Keychain.get("anthropic") == nil {
                Text("Anthropic anahtarı gerekli — Ayarlar → Sohbet'ten ekle.").font(.caption).foregroundStyle(.orange)
            }
            if let error = engine.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        SettingsGroup(title: "Serçe'nin sesi", footer: "Mac sesleri arasında en kalitelisi kendiliğinden seçilir. Premium sesler için: Sistem Ayarları → Erişilebilirlik → Sözlü İçerik → Sesler.") {
            Picker("Ses", selection: $female) {
                Text("Kadın").tag(true)
                Text("Erkek").tag(false)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Perde")
                Slider(value: $pitch, in: 0.7...1.6)
            }
            Toggle("ElevenLabs kullan", isOn: $eleven)
            if eleven {
                SecretField(title: "ElevenLabs anahtarı", key: "elevenlabs")
                HStack {
                    Text("Ses kimliği").frame(width: 150, alignment: .leading)
                    TextField("Boş bırakılırsa varsayılan", text: $elevenVoice).textFieldStyle(.roundedBorder)
                }
            }
            Button("Dene") { engine.preview() }
        }
    }
}

enum VoiceFeature {
    @MainActor static func register(_ app: AppState) {
        SettingsRegistry.shared.add(SettingsSection(id: "ses", title: "Ses", icon: "waveform", order: 40) {
            AnyView(VoiceSettings(engine: .shared))
        })
        VoiceHooks.composeMail = { to, subject, body in
            MailComposer.compose(to: to, subject: subject, body: body, attachments: [])
        }
        VoiceHooks.music = { action, query, level in await music(action, query, level) }
        VoiceEngine.shared.start()
    }

    /// Önce çalan, sonra açık olan, en son kurulu olan müzik uygulamasını seçer (Spotify öncelikli).
    @MainActor private static func music(_ action: String, _ query: String?, _ level: Int?) async -> String {
        let all = MusicController.all
        func isRunning(_ c: MusicController) -> Bool {
            let bid = c.id == "spotify" ? "com.spotify.client" : "com.apple.Music"
            return !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
        }
        let target = all.first { $0.now?.playing == true } ?? all.first(where: isRunning)
            ?? all.first { $0.isConfigured }
        guard let c = target else { return "Spotify ya da Apple Music bulunamadı." }
        if !AppState.shared.pills.isActive(c.id) { c.start() }
        switch action {
        case "play":
            guard let q = query, !q.isEmpty else { c.playPause(); return "\(c.title) devam ediyor." }
            return await c.play(query: q) ? "\(c.title)'da \(q) çalınıyor." : "\(c.title)'da \(q) bulunamadı."
        case "pause", "resume":
            c.playPause()
            return action == "pause" ? "\(c.title) duraklatıldı." : "\(c.title) devam ediyor."
        case "next": c.next(); return "Sonraki parça."
        case "previous": c.previous(); return "Önceki parça."
        case "volume":
            c.setVolume(Double(level ?? 50))
            return "Ses %\(level ?? 50)."
        default: return "Bilinmeyen müzik eylemi."
        }
    }
}
