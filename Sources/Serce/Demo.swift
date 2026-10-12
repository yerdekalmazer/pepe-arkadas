import AppKit
import SwiftUI

/// Demo ve anlık görüntü için örnek bir Claude Code oturumu: oku, düzenle, test et.
enum DemoScript {
    static func make() -> (steps: [(Double, HookEvent)], after: [(Double, HookEvent)]) {
        let sid = "demo-\(Int.random(in: 1000...9999))"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = home + "/Projeler/kesit"
        func ev(_ name: String, _ extra: [String: Any] = [:]) -> HookEvent {
            var p: [String: Any] = ["session_id": sid, "cwd": dir, "hook_event_name": name]
            p.merge(extra) { $1 }
            return HookEvent(name: name, payload: p, bundleId: "com.mitchellh.ghostty", term: "ghostty")
        }
        let file = dir + "/src/fatura.ts"
        let original = "import { Kalem } from './tipler'\n\nconst KDV = 0.18\n\nexport function toplam(kalemler: Kalem[]) {\n  const ara = kalemler.reduce((s, k) => s + k.fiyat, 0)\n  return ara * (1 + KDV)\n}\n"
        let editInput: [String: Any] = ["file_path": file, "old_string": "const KDV = 0.18", "new_string": "const KDV = 0.20 // 2026"]
        let bashInput: [String: Any] = ["command": "npm test", "description": "Testleri çalıştır"]
        let steps: [(Double, HookEvent)] = [
            (0.0, ev("SessionStart")),
            (0.5, ev("UserPromptSubmit", ["prompt": "KDV oranını %20 yap ve testleri çalıştır"])),
            (1.2, ev("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": file]])),
            (2.2, ev("PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": file],
                                    "tool_response": ["type": "text", "file": ["filePath": file, "content": original, "startLine": 1]]])),
            (3.0, ev("PreToolUse", ["tool_name": "Edit", "tool_input": editInput])),
            (4.0, ev("PostToolUse", ["tool_name": "Edit", "tool_input": editInput, "tool_response": ["structuredPatch": [[
                "oldStart": 1, "oldLines": 8, "newStart": 1, "newLines": 8,
                "lines": [" import { Kalem } from './tipler'", " ", "-const KDV = 0.18", "+const KDV = 0.20 // 2026", " ",
                          " export function toplam(kalemler: Kalem[]) {", "   const ara = kalemler.reduce((s, k) => s + k.fiyat, 0)",
                          "   return ara * (1 + KDV)", " }"]]]]])),
            (5.0, ev("PreToolUse", ["tool_name": "Bash", "tool_input": bashInput])),
            (5.2, ev("PermissionRequest", ["tool_name": "Bash", "tool_input": bashInput,
                                          "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                                                      "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]]]]])),
        ]
        let after: [(Double, HookEvent)] = [
            (1.5, ev("PostToolUse", ["tool_name": "Bash", "tool_input": bashInput, "tool_response": [
                "stdout": "> kesit@1.0.0 test\n> vitest run\n\n ✓ tests/fatura.test.ts (6)\n   ✓ KDV %20 uygulanır (3 ms)\n\n Test Files  1 passed (1)\n      Tests  48 passed (48)", "stderr": ""]])),
            (2.3, ev("Stop", ["last_assistant_message": "KDV oranını **%20** yaptım ve `npm test` çalıştırdım: 48 testin hepsi geçti.\n\nDeğişen dosya: `src/fatura.ts`. Fatura PDF şablonundaki oran metnini de güncellememi ister misin?"])),
        ]
        return (steps, after)
    }
}

/// Demo oturumunu adım adım oynatır ve her ana görünümü PNG olarak kaydeder (ekranla etkileşim yok).
@MainActor enum Snapshot {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Demo olayları gerçek haftalık özete yazılmasın.
        RecapStore.fileURL = dir.appendingPathComponent("haftalik.json")
        let app = AppState.shared
        let store = app.store
        let model = NotchModel()
        model.expanded = true
        model.hooksInstalled = true
        model.notchWidth = 185
        model.notchHeight = 32
        let actions = NotchActions(decide: { _, _ in }, openTerminal: { _ in }, installHooks: {}, showMenu: {})
        let (steps, after) = DemoScript.make()

        func shot(_ name: String) {
            let view = ExpandedView(app: app, store: store, pills: app.pills, model: model, actions: actions)
                .frame(width: model.expandedWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(NotchShape(ear: model.ear, radius: 26).fill(.black))
                .environment(\.colorScheme, .dark)
                .environment(\.snapshotMode, true)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
            }
        }

        let responder = Responder { _ in }
        for (i, (_, e)) in steps.enumerated() {
            _ = store.handle(e, responder: e.name == "PermissionRequest" ? responder : nil)
            if i == 4 { shot("1-ana-calisiyor") }
        }
        shot("2-izin")
        if let a = store.approvals.first { store.decide(a, .allow) }
        for (_, e) in after { _ = store.handle(e) }
        model.selectedSession = nil
        shot("3-ana-bitti")
        model.selectedSession = store.sessions.first?.id
        shot("4-detay-terminal")
        model.pinnedStep = store.sessions.first?.steps.first { $0.tool == "Edit" }?.id
        shot("5-detay-diff")
        model.pinnedStep = store.sessions.first?.steps.first { $0.tool == "Read" }?.id
        shot("6-detay-okuma")
        model.pinnedStep = nil
        model.selectedSession = nil
        AgentSnapshots.run(store: store, model: model, actions: actions, shot: shot, shotView: { name, view in
            let wrapped = view
                .padding(14)
                .frame(width: model.expandedWidth - 2 * (model.ear + 12), alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.panel))
                .padding(.horizontal, model.ear + 12).padding(.vertical, 12)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
                .environment(\.snapshotMode, true)
            let r = ImageRenderer(content: wrapped)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
            }
        })

        // Karakter: kıyafetler, tepkiler, ayar bölümleri.
        func save<V: View>(_ name: String, _ view: V) {
            let r = ImageRenderer(content: view.environment(\.colorScheme, .dark).environment(\.snapshotMode, true))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
            }
        }
        let outfits = LazyVGrid(columns: Array(repeating: GridItem(.fixed(120)), count: 4), spacing: 14) {
            ForEach(Outfit.allCases) { o in
                VStack(spacing: 6) {
                    Bird(mood: .idle, size: 96, outfit: o, eyes: .fixed)
                    Text(o.title).font(.system(size: 12)).foregroundStyle(.white)
                }
            }
        }
        .padding(20).background(Color.black)
        save("7-kiyafetler", outfits)
        let emotes = HStack(spacing: 40) {
            ForEach(Array([(BirdEmote.annoyed, 0.5, "sinirli"), (.dizzy, 1.0, "başı dönmüş"), (.greet, 0.4, "selam"),
                           (.bubble("📸"), 0.5, "baloncuk")].enumerated()), id: \.offset) { _, e in
                VStack(spacing: 8) {
                    Bird(mood: .idle, size: 110, eyes: .fixed, frozenEmote: (e.0, e.1))
                    Text(e.2).font(.system(size: 12)).foregroundStyle(.white)
                }
            }
        }
        .padding(30).padding(.trailing, 30).background(Color.black)
        save("8-tepkiler", emotes)
        let small = HStack(spacing: 16) {
            ForEach([Outfit.none, .beanie, .crown, .santa, .partyHat], id: \.self) { o in
                Bird(mood: .idle, size: 25, outfit: o, eyes: .fixed)
            }
        }
        .padding(10).background(Color.black)
        save("9-notch-boyutu", small)
        save("10-ayar-karakter", VStack(alignment: .leading) { CharacterSettings(character: .shared) }
            .frame(width: 560).padding(20).background(Color(nsColor: .windowBackgroundColor)))
        save("11-ayar-kisayollar", VStack(alignment: .leading) { ShortcutSettings(center: .shared) }
            .frame(width: 560).padding(20).background(Color(nsColor: .windowBackgroundColor)))
        // Entegrasyon pill'leri: örnek JSON → gerçek ayrıştırıcı → kart
        model.selectedSession = nil
        model.pinnedStep = nil
        app.pills.persists = false
        for id in app.pills.activeIds { app.pills.setActive(id, false) }
        let samples = IntegrationSamples.pills()
        for p in samples { app.pills.register(p) }
        for id in ["stripe", "github", "vercel", "n8n"] { app.pills.setActive(id, true) }
        app.selectedPill = nil
        shot("7-ana-pill-izgarasi")
        for p in samples {
            app.selectedPill = p.id
            shot("8-pill-\(p.id)")
        }
        if let stripe = samples.first as? StripePill {
            stripe.model = nil
            stripe.status = .failed("Anahtar geçersiz")
            app.selectedPill = "stripe"
            shot("9-pill-baglanamadi")
        }
        for p in samples { print("ses[\(p.id)]: \(p.voiceSummary)") }
        // Sohbet ve dosya bırakma
        model.selectedSession = nil
        let chat = ChatSession.shared
        app.tab = .chat
        shot("7-sohbet-bos")
        chat.messages = [
            ChatMessage(role: .user, text: "Günümü özetle"),
            ChatMessage(role: .assistant, text: "**kesit** oturumu bitti: KDV oranı %20'ye çekildi, `npm test` ile 48 testin hepsi geçti. Başka açık oturum yok."),
            ChatMessage(role: .user, text: "Bu dosyada ne var?", attachmentNames: ["fatura.ts"]),
            ChatMessage(role: .assistant, text: ""),
        ]
        shot("8-sohbet")
        chat.messages.removeLast()
        app.attachments = [Attachment(name: "rapor.pdf", kind: .text("")), Attachment(name: "ekran.png", kind: .text(""))]
        chat.draft = "Bunları karşılaştır"
        shot("9-sohbet-ekli")
        app.tab = .drop
        app.attachments = []
        shot("10-birak")
        app.attachments = [Attachment(name: "sunum.pdf", kind: .text("")), Attachment(name: "app.swift", kind: .text(""))]
        shot("11-birak-ekli")
        app.attachments = []
        chat.newChat()
        app.tab = .home
        voiceShots(into: dir)
        // Kişisel katman: hatırlatma şeridi + sabah brifingi (gerçek proje hafızasından, salt okuma)
        app.tab = .home
        model.selectedSession = nil
        app.selectedPill = nil
        Reminders.shared.showForSnapshot("Tessera 1.4'ü App Store incelemesine gönder", project: "tessera-ios")
        _ = Briefing.shared.text(weekly: true)
        Briefing.shared.visible = true
        shot("15-kisisel")
        model.newSessionCwd = FileManager.default.homeDirectoryForCurrentUser.path + "/Desktop/Projeler/Bireysel/serce"
        shot("16-yeni-oturum")
        model.newSessionCwd = nil
        Briefing.shared.visible = false
        musicShots(into: dir)
    }

    /// Sesli asistan baloncuğu: kapalı ada + altında dinliyor/düşünüyor/konuşuyor.
    static func voiceShots(into dir: URL) {
        let v = VoiceEngine.shared
        let states: [(String, VoiceEngine.Phase, String, String)] = [
            ("12-ses-dinliyor", .listening, "Stripe'ta bugün ne kadar kazandım", ""),
            ("13-ses-dusunuyor", .thinking, "Stripe'ta bugün ne kadar kazandım", ""),
            ("14-ses-konusuyor", .speaking, "", "Bugün 3 ödeme aldın, toplam 1.284 euro 50 sent. Sonuncusu Sarah'dan 49 euro."),
        ]
        for (name, phase, heard, answer) in states {
            v.showForSnapshot(phase, heard: heard, answer: answer)
            let view = VStack(spacing: 6) {
                NotchShape(ear: 7, radius: 12).fill(.black).frame(width: 279, height: 32)
                VoiceCaption(engine: v)
            }
            .padding(20)
            .frame(width: 520)
            .background(Color(white: 0.55))
            .environment(\.snapshotMode, true)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
            }
        }
        v.showForSnapshot(.off, heard: "", answer: "")
    }

    /// Müzik kartları: sahte durumla, AppleScript göndermeden.
    static func musicShots(into dir: URL) {
        func render(_ name: String, _ c: MusicController) {
            let view = HStack(alignment: .top, spacing: 10) {
                c.card().frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(spacing: 6) {
                    PillChip(title: "Claude Code", color: .white, selected: false, attention: false) {}
                    PillChip(title: c.title, color: c.color, selected: true, attention: false) {}
                }
                .frame(width: 230)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.panel))
            .padding(12)
            .frame(width: 660)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .environment(\.snapshotMode, true)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
            }
        }
        let spotify = MusicController(.spotify)
        let raw = ["playing", "One More Time", "Daft Punk", "Discovery", "320357", "101,5", "true", "false", "64", ""]
            .joined(separator: MusicApp.separator)
        spotify.preview(MusicApp.parse(raw, app: .spotify))
        render("7-spotify", spotify)

        let music = MusicController(.music)
        let raw2 = ["paused", "Gönül Dağı", "Neşet Ertaş", "Gönül Dağı", "245.3", "200.1", "false", "one", "80", ""]
            .joined(separator: MusicApp.separator)
        music.preview(MusicApp.parse(raw2, app: .music))
        render("8-apple-music", music)

        music.preview(nil, running: false)
        render("9-muzik-kapali", music)
    }
}
