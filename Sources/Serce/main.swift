import AppKit
import ServiceManagement
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var store: SessionStore { AppState.shared.store }
    private var server: HookServer!
    private var notch: NotchController!
    private var statusItem: NSStatusItem!
    /// Karardan hemen sonra kart değişir; aynı noktaya düşen ikinci tıklama yeni çıkan butona basmasın.
    private var lastDecision = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        Support.prepare()

        notch = NotchController(store: store, actions: NotchActions(
            decide: { [weak self] a, d in
                guard let self, Date().timeIntervalSince(self.lastDecision) > 0.5 else { return }
                self.lastDecision = Date()
                self.store.decide(a, d)
                self.notch.settle()
            },
            openTerminal: { [weak self] s in self?.store.openTerminal(for: s) },
            installHooks: { [weak self] in
                guard let self, Date().timeIntervalSince(self.lastDecision) > 0.8 else { return }
                self.toggleHooks()
            },
            showMenu: { SettingsWindowController.shared.show() },
            answer: { [weak self] q, selections in
                guard let self, Date().timeIntervalSince(self.lastDecision) > 0.5 else { return }
                self.lastDecision = Date()
                self.store.answer(q, selections: selections)
                self.notch.settle()
            },
            questionToTerminal: { [weak self] q in
                self?.store.questionToTerminal(q)
                self?.notch.settle()
            }
        ))
        notch.show()
        AppWindowController.shared.configure(actions: notch.actions)

        let app = AppState.shared
        app.actions.expand = { [weak self] in self?.notch.setExpanded(true) }
        app.actions.collapse = { [weak self] in self?.notch.setExpanded(false) }
        app.actions.openTab = { [weak self] tab in
            app.tab = tab
            self?.notch.setExpanded(true)
        }
        app.actions.openSettings = { SettingsWindowController.shared.show() }
        app.actions.isExpanded = { [weak self] in self?.notch.model.expanded ?? false }
        app.actions.openTerminal = { [weak self] s in self?.store.openTerminal(for: s) }
        app.actions.jumpToAlert = { [weak self] in
            if app.store.hasPending { self?.notch.setExpanded(true) }
        }
        CoreSettings.register(app)
        Features.register(app)

        let store = self.store
        server = HookServer(token: Support.token) { event, responder, onClose in
            Task { @MainActor in
                guard let id = store.handle(event, responder: responder) else { return }
                onClose { Task { @MainActor in store.dropApproval(id) } }
            }
        }
        do {
            try server.start()
        } catch {
            alert("Pepe dinlemeye başlayamadı", "\(Support.port) numaralı port kullanımda olabilir.\n\(error.localizedDescription)")
        }

        setupStatusItem()
        if ProcessInfo.processInfo.environment["SERCE_DEMO"] == "1" { runDemo() }
    }

    // MARK: - Menü çubuğu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Pepe")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let installed = HookInstaller.isInstalled()
        menu.addItem(withTitle: installed ? "Claude Code'a bağlı ✓" : "Claude Code'a bağlı değil", action: nil, keyEquivalent: "")
        menu.addItem(item(installed ? "Bağlantıyı kaldır" : "Claude Code'a bağla", #selector(toggleHooks)))
        menu.addItem(.separator())
        let sound = item("Sesler", #selector(toggleSound))
        sound.state = store.soundsOn ? .on : .off
        menu.addItem(sound)
        let login = item("Girişte başlat", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Pencerede aç", #selector(openWindow)))
        menu.addItem(item("Ayarlar…", #selector(openSettings), key: ","))
        menu.addItem(item("Demo göster", #selector(runDemo)))
        menu.addItem(.separator())
        menu.addItem(item("Pepe'den çık", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc func toggleHooks() {
        do {
            if HookInstaller.isInstalled() { try HookInstaller.uninstall() } else { try HookInstaller.install() }
            notch.model.hooksInstalled = HookInstaller.isInstalled()
        } catch {
            alert("Ayar dosyası değiştirilemedi", error.localizedDescription)
        }
    }

    @objc private func toggleSound() { store.soundsOn.toggle() }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc func openSettingsFromMenu() { SettingsWindowController.shared.show() }
    @objc private func openWindow() { AppWindowController.shared.show() }

    /// Dock simgesine tıklanınca pencereyi geri getir.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppWindowController.shared.show() }
        return true
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Girişte başlatma ayarlanamadı", error.localizedDescription)
        }
    }

    @objc private func quit() {
        for a in store.approvals { store.decide(a, .terminal) }
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }

    // MARK: - Demo

    /// Gerçek bir oturumu taklit eder: iş, izin isteği, bitiş. Kararlar hiçbir yere gitmez.
    @objc func runDemo() {
        let (steps, after) = DemoScript.make()
        for (delay, e) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let responder = e.name == "PermissionRequest" ? Responder { body in
                    NSLog("Pepe demo kararı: \(body.isEmpty ? "(terminal)" : body)")
                    for (d, e2) in after {
                        DispatchQueue.main.asyncAfter(deadline: .now() + d) { _ = self.store.handle(e2) }
                    }
                } : nil
                _ = self.store.handle(e, responder: responder)
            }
        }
    }
}

MainActor.assumeIsolated {
    // Derleme betiği ikonu kuşun kendi çiziminden üretir: Serce --render-icon cikti.png
    if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
        let view = ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous).fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                .frame(width: 824, height: 824)
            Bird(mood: .idle, size: 600).offset(y: 30)
        }
        .frame(width: 1024, height: 1024)
        let r = ImageRenderer(content: view)
        r.scale = 1
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        exit(0)
    }
    // Uyandırma sözü eşleyicisinin hızlı denetimi: Serce --selftest-wake
    if CommandLine.arguments.contains("--selftest-wake") {
        let cases: [(String, String?)] = [
            ("OK Pepe Stripe'ta bugün ne kazandım", "Stripe'ta bugün ne kazandım"),
            ("okey pepe, biraz müzik çal", "biraz müzik çal"),
            ("Hey Pepe hava nasıl", "hava nasıl"),
            ("pepe çok tatlı bir köpek", nil),
            ("bugün ok dedim pepe gördüm", nil),
        ]
        var ok = true
        for (input, want) in cases {
            let got = WakePhrase.match(in: input).map { String(input[$0...]) }
            let pass = got == want
            ok = ok && pass
            print(pass ? "✓" : "✗", input, "→", got ?? "nil")
        }
        exit(ok ? 0 : 1)
    }
    // Sohbet akış ayrıştırıcılarının örnek akışlarla sınanması: Serce --selftest
    if CommandLine.arguments.contains("--selftest") {
        exit(ChatSelfTest.run() ? 0 : 1)
    }
    // Ajan kurucularını geçici klasörde dener: Serce --ajan-testi klasor
    if let i = CommandLine.arguments.firstIndex(of: "--ajan-testi"), i + 1 < CommandLine.arguments.count {
        AgentSelfTest.run(home: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    }
    // MCP bağlantılarını gerçek sunuculara karşı dener (tarayıcı açmaz): Serce --mcp-test
    if CommandLine.arguments.contains("--mcp-test") {
        Task { @MainActor in
            await MCPHub.shared.selfTest()
            exit(0)
        }
        RunLoop.main.run()
    }
    // Proje hafızasını geçici klasörde dener (LLM çağrısı yok): Serce --hafiza-testi klasor
    if let i = CommandLine.arguments.firstIndex(of: "--hafiza-testi"), i + 1 < CommandLine.arguments.count {
        let base = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        ProjectMemory.dirOverride = base.appendingPathComponent("Hafiza")
        UserDefaults.standard.set(false, forKey: "hafizaOzet")
        let repo = base.appendingPathComponent("ornek-proje")
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        let cwd = repo.appendingPathComponent("src").path
        func ev(_ name: String, _ extra: [String: Any] = [:]) -> HookEvent {
            var p: [String: Any] = ["session_id": "t1", "cwd": cwd]
            p.merge(extra) { $1 }
            return HookEvent(name: name, payload: p, bundleId: "", term: "")
        }
        let mem = ProjectMemory.shared
        mem.observe(ev("UserPromptSubmit", ["prompt": "Supabase bağlantısını session pooler'a çevir ve testleri çalıştır"]))
        mem.observe(ev("PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": repo.path + "/src/db.ts"]]))
        mem.observe(ev("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "npm test"], "tool_response": ["stdout": "48 passed", "stderr": ""]]))
        mem.observe(ev("Stop", ["last_assistant_message": "Bağlantı aws-1 session pooler'a alındı, 48 test geçti."]))
        mem.observe(ev("SessionEnd"))
        let md = ProjectDoc.url(for: repo.path)
        print("── md (\(md.lastPathComponent)):")
        print((try? String(contentsOf: md, encoding: .utf8)) ?? "YOK")
        print("── SessionStart bağlamı:")
        print(ProjectMemory.sessionContext(cwd: cwd) ?? "YOK")
        print("── arama 'session pooler':", ProjectMemory.search("session pooler"))
        print("── tohum: \(ProjectMemory.seedFromNotes()) proje md'si oluşturuldu")
        print(ProjectMemory.allDocs().map { "\($0.name) ← \($0.root.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" }.joined(separator: "\n"))
        if let k = ProjectMemory.find("koridor") { print("── koridor özeti:\n" + k.section("Özet").prefix(400)) }
        var msgs: [ChatMessage] = []
        for n in 0..<20 {
            var m = ChatMessage(role: n % 2 == 0 ? .user : .assistant, text: "m\(n)")
            if n == 4 || n == 18 { m.parts = [.image(mime: "image/png", base64: "AAAA")]; m.attachmentNames = ["g\(n).png"] }
            msgs.append(m)
        }
        let t = ChatSession.trimmed(msgs)
        print("── kırpma: \(t.count) mesaj, ilk \(t.first?.text ?? ""), ekli: \(t.filter { !$0.parts.isEmpty }.map(\.text))")
        exit(0)
    }
    // Pepe'den oturum başlatma ve sürdürme (terminalsiz): Serce --gonder-testi klasor
    if let i = CommandLine.arguments.firstIndex(of: "--gonder-testi"), i + 1 < CommandLine.arguments.count {
        let dir = CommandLine.arguments[i + 1]
        Task { @MainActor in
            AgentRunner.modelOverride = "haiku"
            let r = AgentRunner.shared
            @MainActor func wait(_ key: String) async { while r.isRunning(key) { try? await Task.sleep(for: .milliseconds(300)) } }
            print("başlat:", r.start("Aklında tut: gizli kelime 'serçe42'. Sadece 'tamam' yaz.", in: dir) ?? "ok")
            // Yeni oturumlar oturum kimliğiyle izlenir.
            let key = r.running.keys.first ?? dir
            await wait(key)
            let first = r.lastResult[key]
            print("1. yanıt:", first?.text ?? "-", "| hata:", r.lastError[dir] ?? "yok")
            guard let sid = first?.sessionId, !sid.isEmpty else { exit(1) }
            let s = AgentSession(id: sid, cwd: dir, status: .done)
            print("devam:", r.send("Gizli kelime neydi? Sadece kelimeyi yaz.", to: s) ?? "ok")
            await wait(sid)
            print("2. yanıt:", r.lastResult[sid]?.text ?? "-", "| hata:", r.lastError[sid] ?? "yok")
            // Görselli mesaj (16x16 kırmızı PNG)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 3,
                                       hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for x in 0..<16 { for y in 0..<16 { rep.setColor(NSColor(deviceRed: 0.85, green: 0.1, blue: 0.1, alpha: 1), atX: x, y: y) } }
            let png = rep.representation(using: .png, properties: [:])!
            print("görsel:", r.send("Bu görselin rengi ne? Tek kelime.", images: [png], to: s) ?? "ok")
            await wait(sid)
            print("3. yanıt:", r.lastResult[sid]?.text ?? "-", "| hata:", r.lastError[sid] ?? "yok")
            exit(0)
        }
        RunLoop.main.run()
    }
    // Test ve anlık görüntü modları gerçek sohbet geçmişine dokunmaz.
    if CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { ChatSession.persist = false }
    // Kişisel katman: brifing (gerçek hafıza, salt okuma), tarih ayrıştırma, Trello okuma ve yazma koruması: Serce --kisisel-testi klasor
    if let i = CommandLine.arguments.firstIndex(of: "--kisisel-testi"), i + 1 < CommandLine.arguments.count {
        Task { @MainActor in
            print("── brifing (haftalık):\n" + Briefing.shared.text(weekly: true))
            for s in ["2026-10-13 10:00", "2026-10-13T09:30", "yarın"] { print("parse \(s) →", Reminders.parse(s).map { Reminders.format($0) } ?? "nil") }
            ProjectMemory.dirOverride = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            AboutMe.seedIfNeeded()
            print("── ben (istem bloğu, \(AboutMe.promptBlock().count) karakter):" + AboutMe.promptBlock().prefix(700))
            do {
                let (b, l) = try await TrelloAPI.resolve(board: nil, list: "Inbox")
                let cards = try await TrelloAPI.cards(list: l!)
                print("── Trello \(b.name) › \(l!.name): \(cards.count) kart")
                let pill = TrelloPill(); pill.refresh(); try? await Task.sleep(for: .seconds(6)); print("── pill sesli özet:", pill.voiceSummary)
                if let other = try await TrelloAPI.boards().first(where: { !TrelloAPI.isWritable($0.name) }) {
                    do { _ = try await TrelloAPI.addCard(board: other.name, list: "x", name: "x", desc: "") ; print("✗ koruma çalışmadı!") }
                    catch { print("✓ yazma koruması (\(other.name)):", error.localizedDescription) }
                }
            } catch { print("Trello hata:", error.localizedDescription) }
            exit(0)
        }
        RunLoop.main.run()
    }
    // Aynı projede paralel iki oturum (biri ayrı çalışma kopyasında): Serce --paralel-testi git-deposu
    if let i = CommandLine.arguments.firstIndex(of: "--paralel-testi"), i + 1 < CommandLine.arguments.count {
        let repo = CommandLine.arguments[i + 1]
        AgentRunner.modelOverride = "haiku"
        Task { @MainActor in
            AgentRunner.modelOverride = "haiku"
            let r = AgentRunner.shared
            print("1:", r.start("Sadece 'bir' yaz.", in: repo) ?? "başladı")
            print("2:", r.start("Sadece pwd komutunun çıktısını yaz.", in: repo, worktree: true) ?? "başladı (worktree)")
            print("eşzamanlı çalışan:", r.running.count)
            while !r.running.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            for (k, v) in r.lastResult { print("•", k.prefix(8), "→", v.text.prefix(120), r.lastError[k] ?? "") }
            for s in AppState.shared.store.sessions { print("kart:", s.project, s.worktree ?? "-", s.launchedBySerce) }
            exit(0)
        }
        RunLoop.main.run()
    }
    // Oturum kapatma ve SessionEnd davranışı (sahte "claude" süreciyle): Serce --kapat-testi klasor
    if let i = CommandLine.arguments.firstIndex(of: "--kapat-testi"), i + 1 < CommandLine.arguments.count {
        Task { @MainActor in
            let store = AppState.shared.store
            func ev(_ name: String, sid: String, serce: Bool, pid: Int32 = 0) -> HookEvent {
                var e = HookEvent(name: name, payload: ["session_id": sid, "cwd": "/tmp"], bundleId: "", term: "")
                e.fromSerce = serce
                e.pid = pid
                return e
            }
            _ = store.handle(ev("UserPromptSubmit", sid: "a", serce: true))
            _ = store.handle(ev("SessionEnd", sid: "a", serce: true))
            print("Pepe çalıştırması bitti → kart duruyor:", store.sessions.contains { $0.id == "a" && !$0.ended } ? "✓" : "✗")
            _ = store.handle(ev("UserPromptSubmit", sid: "b", serce: false))
            _ = store.handle(ev("SessionEnd", sid: "b", serce: false))
            print("Terminal kapandı → kart 'kapalı':", store.sessions.first { $0.id == "b" }?.ended == true ? "✓" : "✗")

            let fake = URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent("claude")
            try? FileManager.default.removeItem(at: fake)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: fake)
            let p = Process()
            p.executableURL = fake
            p.arguments = ["300"]
            try? p.run()
            _ = store.handle(ev("UserPromptSubmit", sid: "c", serce: false, pid: p.processIdentifier))
            let s = store.sessions.first { $0.id == "c" }!
            print("kapat:", store.closeSession(s) ?? "gönderildi")
            try? await Task.sleep(for: .seconds(4))
            print("süreç kapandı:", p.isRunning ? "✗" : "✓", "| kart kapalı:", store.sessions.first { $0.id == "c" }?.ended == true ? "✓" : "✗")
            exit(0)
        }
        RunLoop.main.run()
    }
    // Oturum dökümü okuyucusu: Serce --gecmis-testi dosya.jsonl
    if let i = CommandLine.arguments.firstIndex(of: "--gecmis-testi"), i + 1 < CommandLine.arguments.count {
        let t0 = Date()
        let (items, truncated) = TranscriptReader.read(path: CommandLine.arguments[i + 1], bytes: 2 << 20)
        print("\(items.count) öğe, daha eskisi var: \(truncated), süre: \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        let (acts, _) = TranscriptReader.activity(path: CommandLine.arguments[i + 1], bytes: 4 << 20)
        let byTool = Dictionary(grouping: acts, by: \.tool).mapValues(\.count).sorted { $0.value > $1.value }
        print("adımlar: \(acts.count) —", byTool.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let (cmds, _) = TranscriptReader.commands(path: CommandLine.arguments[i + 1], bytes: 4 << 20)
        print("komut: \(cmds.count), hatalı: \(cmds.filter(\.isError).count), sonuçsuz: \(cmds.filter(\.running).count)")
        for c in cmds.suffix(3) { print("  $", c.command.prefix(70).replacingOccurrences(of: "\n", with: " "), "→", c.output.count, "karakter") }
        for it in items.suffix(12) {
            let tag = it.kind == .user ? "SEN   " : (it.kind == .assistant ? "CLAUDE" : "adım  ")
            print(tag, it.text.replacingOccurrences(of: "\n", with: " ").prefix(90))
        }
        exit(0)
    }
    // Mesaj kuyruğu: çalışan oturuma yazılan mesaj sıraya alınır, Stop gelince gönderilir: Serce --kuyruk-testi klasor
    if let i = CommandLine.arguments.firstIndex(of: "--kuyruk-testi"), i + 1 < CommandLine.arguments.count {
        Task { @MainActor in
            let store = AppState.shared.store, c = ComposerStore.shared
            let sid = "00000000-0000-4000-8000-000000000001", cwd = CommandLine.arguments[i + 1]
            _ = store.handle(HookEvent(name: "UserPromptSubmit", payload: ["session_id": sid, "cwd": cwd, "prompt": "x"], bundleId: "", term: ""))
            c.setText("şunu da ekle", for: sid)
            c.addImage(Data([0x89, 0x50, 0x4E, 0x47]), to: sid)
            let s = store.sessions.first { $0.id == sid }!
            print("çalışırken gönder:", c.submit(for: s) ?? "ok", "| sırada:", c.queued[sid] != nil, "| taslak boş:", c.draft(sid).isEmpty)
            _ = store.handle(HookEvent(name: "Stop", payload: ["session_id": sid, "cwd": cwd], bundleId: "", term: ""))
            try? await Task.sleep(for: .milliseconds(300))
            print("Stop sonrası: sırada:", c.queued[sid] != nil, "| gönderim başladı:", AgentRunner.shared.isRunning(sid))
            while AgentRunner.shared.isRunning(sid) { try? await Task.sleep(for: .milliseconds(300)) }
            print("claude sonucu:", (AgentRunner.shared.lastError[sid] ?? "hata yok").prefix(90))
            exit(0)
        }
        RunLoop.main.run()
    }
    // Ekrana dokunmadan arayüz görüntüsü: Serce --snapshot klasor
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        Snapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
