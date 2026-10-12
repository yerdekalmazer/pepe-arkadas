import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

/// Masaüstü kuşu: adadan aşağı sürüklenince masaüstünde yaşar, imleci izler, uyarıda adaya uçup döner.
/// Bir pencerenin üstüne bırakılırsa o pencerenin görüntüsünü sohbete ekler.
@MainActor final class DesktopBirdController {
    static let shared = DesktopBirdController()

    private(set) var isOnDesktop = false
    private var panel: NSPanel?
    private weak var app: AppState?
    private var watch: AnyCancellable?
    private var tracker: Timer?
    private var dragFromIsland = false
    /// Sürükleme başlamadan önceki yer (pencereye bırakınca geri dönmek için).
    private var restoreOrigin: CGPoint?
    private var awayForAlert = false
    private var homeOrigin: CGPoint?

    static let panelSize = CGSize(width: 150, height: 130)
    static let birdSize: CGFloat = 100

    func start(_ app: AppState) {
        self.app = app
        if UserDefaults.standard.bool(forKey: "masaustunde"), let o = savedOrigin(), onScreen(o) {
            show(at: o)
        }
        watch = app.store.$approvals.sink { [weak self] list in
            Task { @MainActor in self?.alertChanged(!list.isEmpty) }
        }
    }

    // MARK: - Eve / masaüstüne

    func sendToDesktop() {
        guard let s = screen else { return }
        let o = CGPoint(x: s.frame.midX - Self.panelSize.width / 2, y: s.frame.maxY - 300)
        show(at: notchOrigin)
        fly(to: o) { [weak self] in self?.settle() }
        SoundEngine.shared.play(.whoosh)
    }

    func goHome() {
        guard let panel else { return }
        isOnDesktop = false
        UserDefaults.standard.set(false, forKey: "masaustunde")
        SoundEngine.shared.play(.whoosh)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            panel.animator().setFrame(CGRect(origin: notchOrigin, size: Self.panelSize), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.close() }
        })
    }

    // MARK: - Sürükleme

    /// Adadaki kuştan sürükleme başladığında çağrılır.
    func beginDragFromIsland() {
        guard tracker == nil else { return }
        dragFromIsland = true
        restoreOrigin = isOnDesktop ? panel?.frame.origin : nil
        if panel == nil { show(at: originUnderMouse()) }
        beginTracking()
    }

    func beginDragFromDesktop() {
        guard tracker == nil, let panel else { return }
        dragFromIsland = false
        restoreOrigin = panel.frame.origin
        beginTracking()
    }

    private func beginTracking() {
        let grab = CGPoint(x: Self.panelSize.width / 2, y: Self.panelSize.height / 2)
        tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                let m = NSEvent.mouseLocation
                panel.setFrameOrigin(CGPoint(x: m.x - grab.x, y: m.y - grab.y))
                self.updateAnchor()
                if NSEvent.pressedMouseButtons & 1 == 0 { self.endDrag(at: m) }
            }
        }
    }

    private func endDrag(at p: CGPoint) {
        tracker?.invalidate()
        tracker = nil
        guard let s = screen else { return }

        // Adaya geri bırakıldı: eve dön.
        if p.y > s.frame.maxY - 70, abs(p.x - s.frame.midX) < 260 {
            goHome()
            return
        }
        if let win = WindowPicker.window(at: p) {
            SoundEngine.shared.play(.drop)
            Task { await self.attach(win) }
            if let back = restoreOrigin { fly(to: back) { [weak self] in self?.settle() } } else { goHome() }
            return
        }
        SoundEngine.shared.play(.drop)
        settle()
    }

    private func settle() {
        guard let panel else { return }
        isOnDesktop = true
        UserDefaults.standard.set(true, forKey: "masaustunde")
        UserDefaults.standard.set([Double(panel.frame.origin.x), Double(panel.frame.origin.y)], forKey: "masaustuKonum")
        updateAnchor()
    }

    // MARK: - Uyarı uçuşu

    private func alertChanged(_ alert: Bool) {
        guard isOnDesktop, let panel, tracker == nil else { return }
        if alert, !awayForAlert {
            awayForAlert = true
            homeOrigin = panel.frame.origin
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                panel.animator().setFrame(CGRect(origin: notchOrigin, size: Self.panelSize), display: true)
                panel.animator().alphaValue = 0
            }
        } else if !alert, awayForAlert {
            awayForAlert = false
            let back = homeOrigin ?? panel.frame.origin
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.55
                panel.animator().setFrame(CGRect(origin: back, size: Self.panelSize), display: true)
                panel.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                Task { @MainActor in self?.updateAnchor() }
            }
        }
    }

    // MARK: - Pencere ekleme

    private func attach(_ win: WindowPicker.Info) async {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            let a = NSAlert()
            a.messageText = "Ekran kaydı izni gerekli"
            a.informativeText = "Serçe'nin bir pencereyi sohbete ekleyebilmesi için Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Ses Kaydı listesinde Serçe'yi aç, sonra kuşu tekrar bırak."
            NSApp.activate()
            a.runModal()
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let w = content.windows.first(where: { $0.windowID == win.id }) else { return }
            let cfg = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            cfg.width = Int(w.frame.width * scale)
            cfg.height = Int(w.frame.height * scale)
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                                                   configuration: cfg)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            let name = win.title.isEmpty ? "\(win.owner) penceresi" : "\(win.owner) — \(win.title)"
            app?.attachments.append(Attachment(name: name, kind: .image(png)))
            CharacterState.shared.emote(.bubble("📸"))
            app?.actions.openTab(.chat)
        } catch {
            SoundEngine.shared.play(.error)
            CharacterState.shared.emote(.bubble("?"))
        }
    }

    // MARK: - Pencere

    private func show(at origin: CGPoint) {
        if panel == nil {
            let p = NSPanel(contentRect: CGRect(origin: origin, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.isMovable = false
            if let app {
                let host = NSHostingView(rootView: DesktopBirdView(app: app))
                host.sizingOptions = []
                p.contentView = host
            }
            panel = p
        }
        panel?.alphaValue = 1
        panel?.setFrameOrigin(origin)
        panel?.orderFrontRegardless()
        updateAnchor()
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        isOnDesktop = false
        awayForAlert = false
    }

    private func fly(to origin: CGPoint, then done: @escaping @MainActor () -> Void) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(CGRect(origin: origin, size: Self.panelSize), display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { Task { @MainActor in done() } })
    }

    private func updateAnchor() {
        guard let f = panel?.frame else { return }
        // Kuş panelin sol altında; göz kuşun sağ üst çeyreğinde.
        MouseTracker.desktopAnchor = CGPoint(x: f.minX + 10 + Self.birdSize * 0.64, y: f.minY + 10 + Self.birdSize * 0.56)
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private var notchOrigin: CGPoint {
        guard let s = screen else { return .zero }
        return CGPoint(x: s.frame.midX - Self.panelSize.width / 2 - 100, y: s.frame.maxY - Self.panelSize.height + 30)
    }

    private func originUnderMouse() -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x - Self.panelSize.width / 2, y: m.y - Self.panelSize.height / 2)
    }

    private func savedOrigin() -> CGPoint? {
        guard let v = UserDefaults.standard.array(forKey: "masaustuKonum") as? [Double], v.count == 2 else { return nil }
        return CGPoint(x: v[0], y: v[1])
    }

    private func onScreen(_ o: CGPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(CGPoint(x: o.x + 50, y: o.y + 50)) }
    }
}

struct DesktopBirdView: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: SessionStore

    init(app: AppState) {
        self.app = app
        store = app.store
    }

    var body: some View {
        Bird(mood: app.mood, size: DesktopBirdController.birdSize, interactive: true, eyes: .desktop)
            .simultaneousGesture(TapGesture(count: 2).onEnded { DesktopBirdController.shared.goHome() })
            .gesture(DragGesture(minimumDistance: 4).onChanged { _ in DesktopBirdController.shared.beginDragFromDesktop() })
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            .padding(10)
            .frame(width: DesktopBirdController.panelSize.width, height: DesktopBirdController.panelSize.height,
                   alignment: .bottomLeading)
    }
}

/// Adadaki kuşları sürüklenebilir yapar: aşağı çekilen kuş masaüstüne ya da bir pencerenin üstüne bırakılır.
struct BirdDragSource: ViewModifier {
    func body(content: Content) -> some View {
        content.gesture(DragGesture(minimumDistance: 8).onChanged { v in
            if v.translation.height > 6 { DesktopBirdController.shared.beginDragFromIsland() }
        })
    }
}

extension View {
    func birdDragSource() -> some View { modifier(BirdDragSource()) }
}

/// İmlecin altındaki uygulama penceresini bulur (izin gerektirmez; başlık izin varsa dolu gelir).
enum WindowPicker {
    struct Info {
        let id: CGWindowID
        let owner: String
        let title: String
    }

    static func window(at p: CGPoint) -> Info? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.maxY else { return nil }
        let cg = CGPoint(x: p.x, y: mainHeight - p.y)
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.contains(cg), rect.width > 80, rect.height > 60,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? "Pencere"
            if owner == "Finder", rect.width >= (NSScreen.main?.frame.width ?? 0) { continue }
            return Info(id: id, owner: owner, title: w[kCGWindowName as String] as? String ?? "")
        }
        return nil
    }
}
