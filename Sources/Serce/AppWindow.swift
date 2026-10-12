import AppKit
import SwiftUI

private struct AppWindowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Görünüm çentik adası yerine normal uygulama penceresinde mi? Pencerede sabit yükseklikler esner.
    var appWindow: Bool {
        get { self[AppWindowKey.self] }
        set { self[AppWindowKey.self] = newValue }
    }
}

/// Pepe'yi normal bir uygulama gibi kullanmak için: adanın içeriği boyutlandırılabilir bir pencerede.
/// Pencere açıkken Pepe Dock'ta ve ⌘Tab'da görünür; kapanınca yine yalnızca çentikte yaşar.
@MainActor final class AppWindowController: NSObject, NSWindowDelegate {
    static let shared = AppWindowController()
    /// Pencerenin kendi durumu (seçili oturum vb.); adanınkinden bağımsız.
    let model: NotchModel = {
        let m = NotchModel()
        m.expanded = true
        m.hooksInstalled = HookInstaller.isInstalled()
        return m
    }()
    private(set) var window: NSWindow?
    private var actions: NotchActions?
    private var pasteMonitor: Any?

    func configure(actions: NotchActions) { self.actions = actions }

    var isKey: Bool { window?.isKeyWindow ?? false }

    /// Pencereyi açar; `from` verilirse adada açık olan oturum pencerede de açık gelir.
    func show(from notch: NotchModel? = nil) {
        guard let actions else { return }
        if let notch {
            model.selectedSession = notch.selectedSession
            model.pinnedStep = notch.pinnedStep
            model.newSessionCwd = notch.newSessionCwd
        }
        model.hooksInstalled = HookInstaller.isInstalled()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Pepe"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.minSize = NSSize(width: 700, height: 520)
            w.delegate = self
            w.contentView = NSHostingView(rootView: AppWindowRoot(app: .shared, store: AppState.shared.store,
                                                                  model: model, actions: actions))
            w.center()
            w.setFrameAutosaveName("SerceAnaPencere")
            window = w
            // ⌘V: pencerede bir oturum açıksa panodaki görsel o oturumun mesajına eklenir.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.isKey, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "v",
                      AppState.shared.tab == .home, let sid = self.model.selectedSession,
                      ComposerStore.shared.pasteImages(into: sid) else { return e }
                return nil
            }
        }
        Self.installMainMenu()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Dock simgesi kalkar; ayarlar penceresi açıksa o yine çalışır.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Normal uygulamada metin kutularında ⌘C/⌘V/⌘Z menü üzerinden çalışır; menü yoksa çalışmaz.
    private static func installMainMenu() {
        guard NSApp.mainMenu == nil || NSApp.mainMenu?.items.isEmpty == true else { return }
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Ayarlar…", action: #selector(AppDelegate.openSettingsFromMenu), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Pepe'yi gizle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Pepe'den çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Düzen")
        edit.addItem(withTitle: "Geri al", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Yinele", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tümünü seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Pencere")
        windowMenu.addItem(withTitle: "Küçült", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Kapat", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}

/// Pencere içeriği: adanın açık hali, pencereyi dolduracak şekilde.
struct AppWindowRoot: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchModel
    let actions: NotchActions

    var body: some View {
        ExpandedView(app: app, store: store, pills: app.pills, model: model, actions: actions)
            // Başlık çubuğundaki pencere düğmelerine yer.
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.black)
            .environment(\.appWindow, true)
            .environment(\.colorScheme, .dark)
    }
}
