import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Notch'un üstüne oturan saydam paneli yönetir. Panel hep açık boyutta durur;
/// fare yalnızca siyah adanın üstündeyken tıklamaları yakalar, gerisi alttaki pencerelere geçer.
@MainActor final class NotchController {
    let model = NotchModel()
    private let store: SessionStore
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private let panelSize = CGSize(width: 760, height: 620)
    /// Fare basıldığında sürükleme panosunun sayacı; artarsa yeni bir dosya sürüklemesi başlamıştır.
    private var dragBoardCount = NSPasteboard(name: .drag).changeCount

    init(store: SessionStore, actions: NotchActions) {
        self.store = store
        panel = NotchPanel(contentRect: CGRect(origin: .zero, size: panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        let host = NSHostingView(rootView: NotchRoot(app: .shared, store: store, model: model, actions: actions))
        host.sizingOptions = []
        panel.contentView = host

        store.onAttention = { [weak self] in self?.setExpanded(true) }

        // Yazı bitip başka bir yere tıklanınca (panel klavyeyi bırakınca) fare dışarıdaysa kapan.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.settle() }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
        let track: (NSEvent) -> Void = { [weak self] e in
            let dragging = e.type == .leftMouseDragged
            Task { @MainActor in
                if dragging { self?.fileDragMoved() }
                self?.mouseMoved()
            }
        }
        // Dosya sürükleme algısı için: her basışta sürükleme panosunun sayacını hatırla.
        if let d = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            Task { @MainActor in self?.dragBoardCount = NSPasteboard(name: .drag).changeCount }
        }) {
            monitors.append(d)
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track) {
            monitors.append(g)
        }
        // ⌘V: oturum detayı açıksa ve panoda görsel varsa, görsel o oturumun mesajına eklenir.
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "v",
                  let self, self.model.expanded, AppState.shared.tab == .home,
                  let sid = self.model.selectedSession,
                  ComposerStore.shared.pasteImages(into: sid) else { return e }
            return nil
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in track(e); return e }) {
            monitors.append(l)
        }
    }

    func show() {
        place()
        panel.orderFrontRegardless()
    }

    /// Çentikli ekranı tercih eder; yoksa ana ekranın tepesine sahte bir çentik çizer.
    private func place() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchWidth = f.width - left.width - right.width
            model.notchHeight = screen.safeAreaInsets.top
        } else {
            model.notchWidth = 150
            model.notchHeight = max(24, f.maxY - screen.visibleFrame.maxY)
        }
        panel.setFrame(CGRect(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height,
                              width: panelSize.width, height: panelSize.height), display: true)
        MouseTracker.birdAnchor = CGPoint(x: f.midX - model.notchWidth / 2 - model.wing / 2, y: f.maxY - model.notchHeight / 2)
    }

    /// Kapalı adanın altındaki sesli asistan baloncuğu: tıklanabilir ama adayı açmaz.
    private var captionRect: CGRect {
        guard model.captionHeight > 0, !model.expanded else { return .zero }
        let f = panel.frame, top = f.maxY - model.collapsedSize.height - 6
        return CGRect(x: f.midX - 220, y: top - model.captionHeight, width: 440, height: model.captionHeight)
    }

    private var activeRect: CGRect {
        let size = model.expanded ? CGSize(width: model.expandedWidth, height: model.expandedHeight) : model.collapsedSize
        let f = panel.frame
        return CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        MouseTracker.location = p
        // Ekranın en üst pikseli de sayılsın diye üstten biraz pay bırakılır.
        let inside = activeRect.insetBy(dx: -2, dy: -2).contains(p)
        panel.ignoresMouseEvents = !inside && !captionRect.contains(p)
        if ProcessInfo.processInfo.environment["SERCE_DEBUG"] == "1" {
            NSLog("serce-debug mouse=\(p) rect=\(activeRect) inside=\(inside) expanded=\(model.expanded) h=\(model.expandedHeight)")
        }

        if inside, !model.expanded {
            guard hoverWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverWork = nil
                if self.activeRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) { self.setExpanded(true) }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else if !inside {
            hoverWork?.cancel()
            hoverWork = nil
            // Bekleyen izin varken ve bir alana yazı yazılırken (panel klavyede) ada açık kalır.
            if model.expanded, !store.hasPending, !panel.isKeyWindow, !model.holdOpen { setExpanded(false) }
        }
    }

    /// Notch'un üstüne dosya sürüklenirse ada beklemeden açılır ve + sekmesine geçer.
    private func fileDragMoved() {
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != dragBoardCount,
              board.types?.contains(.fileURL) == true,
              activeRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
        panel.ignoresMouseEvents = false
        // Bir oturumun detayı açıksa sürüklenen görsel o oturumun mesajına gider; + sekmesine atlanmaz.
        let onSession = model.expanded && AppState.shared.tab == .home && model.selectedSession != nil
        if !onSession, AppState.shared.tab != .drop { AppState.shared.tab = .drop }
        if !model.expanded { setExpanded(true) }
    }

    func setExpanded(_ open: Bool) {
        guard model.expanded != open else { return }
        if open { model.hooksInstalled = HookInstaller.isInstalled() }
        model.expanded = open
        panel.ignoresMouseEvents = !open && !activeRect.contains(NSEvent.mouseLocation)
    }

    /// Karar sonrası: fare dışarıdaysa ve başka bekleyen yoksa adayı kapat.
    func settle() {
        if !store.hasPending, !model.holdOpen, !activeRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) {
            setExpanded(false)
        }
    }
}
