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

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
        let track: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.mouseMoved() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track) {
            monitors.append(g)
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
        panel.ignoresMouseEvents = !inside
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
            // Bekleyen izin varken ada açık kalır.
            if model.expanded, !store.hasPending { setExpanded(false) }
        }
    }

    func setExpanded(_ open: Bool) {
        guard model.expanded != open else { return }
        if open { model.hooksInstalled = HookInstaller.isInstalled() }
        model.expanded = open
        panel.ignoresMouseEvents = !open && !activeRect.contains(NSEvent.mouseLocation)
    }

    /// Karar sonrası: fare dışarıdaysa ve başka bekleyen yoksa adayı kapat.
    func settle() {
        if !store.hasPending, !activeRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) {
            setExpanded(false)
        }
    }
}
