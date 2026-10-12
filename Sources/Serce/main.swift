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

        let app = AppState.shared
        app.actions.expand = { [weak self] in self?.notch.setExpanded(true) }
        app.actions.collapse = { [weak self] in self?.notch.setExpanded(false) }
        app.actions.openTab = { [weak self] tab in
            app.tab = tab
            self?.notch.setExpanded(true)
        }
        app.actions.openSettings = { SettingsWindowController.shared.show() }
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
            alert("Serçe dinlemeye başlayamadı", "\(Support.port) numaralı port kullanımda olabilir.\n\(error.localizedDescription)")
        }

        setupStatusItem()
        if ProcessInfo.processInfo.environment["SERCE_DEMO"] == "1" { runDemo() }
    }

    // MARK: - Menü çubuğu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Serçe")
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
        menu.addItem(item("Ayarlar…", #selector(openSettings), key: ","))
        menu.addItem(item("Demo göster", #selector(runDemo)))
        menu.addItem(.separator())
        menu.addItem(item("Serçe'den çık", #selector(quit), key: "q"))
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
                    NSLog("Serçe demo kararı: \(body.isEmpty ? "(terminal)" : body)")
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
    // Ajan kurucularını geçici klasörde dener: Serce --ajan-testi klasor
    if let i = CommandLine.arguments.firstIndex(of: "--ajan-testi"), i + 1 < CommandLine.arguments.count {
        AgentSelfTest.run(home: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
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
