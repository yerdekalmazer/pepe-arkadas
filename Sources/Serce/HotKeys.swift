import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Genel bir klavye kısayolu (Carbon tuş kodu + Carbon değiştirici bitleri).
struct HotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyNames.name(keyCode)
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case toggleIsland, openChat, jumpAlert, terminal, nextPill, mute, desktop, wardrobe, listen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleIsland: "Adayı aç / kapat"
        case .openChat: "Sohbeti aç"
        case .jumpAlert: "Bekleyen uyarıya git"
        case .terminal: "Son oturumun terminaline git"
        case .nextPill: "Sonraki pill"
        case .mute: "Sesi aç / kapat"
        case .desktop: "Pepe'yi masaüstüne gönder / eve çağır"
        case .wardrobe: "Gardırobu aç"
        case .listen: "Pepe'ye konuş (« OK Pepe » demeden)"
        }
    }

    var defaultKey: HotKey {
        let m = UInt32(controlKey | optionKey)
        switch self {
        case .toggleIsland: return HotKey(keyCode: UInt32(kVK_Space), modifiers: m)
        case .openChat: return HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: m)
        case .jumpAlert: return HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: m)
        case .terminal: return HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: m)
        case .nextPill: return HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: m)
        case .mute: return HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: m)
        case .desktop: return HotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: m)
        case .wardrobe: return HotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: m)
        case .listen: return HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: m)
        }
    }
}

/// Carbon RegisterEventHotKey ile genel kısayollar. Uygulama önde olmasa da çalışır, erişilebilirlik izni gerekmez.
@MainActor final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()
    private static let signature: OSType = 0x5352_4345 // "SRCE"

    @Published private(set) var bindings: [ShortcutAction: HotKey] = [:]
    /// Ayarlarda tuş kaydedilirken kısayollar devre dışı kalır.
    @Published var recording: ShortcutAction?
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private weak var app: AppState?

    private init() { load() }

    func start(_ app: AppState) {
        self.app = app
        load()
        installHandler()
        registerAll()
    }

    func set(_ action: ShortcutAction, _ key: HotKey?) {
        bindings[action] = key
        save()
        registerAll()
    }

    func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: "kisayollar")
        load()
        registerAll()
    }

    func suspend(_ on: Bool) {
        if on { unregisterAll() } else { registerAll() }
    }

    // MARK: - Eylemler

    func perform(_ action: ShortcutAction) {
        guard let app else { return }
        switch action {
        case .toggleIsland:
            if app.actions.isExpanded() { app.actions.collapse() } else { app.actions.expand() }
        case .openChat:
            app.actions.openTab(.chat)
        case .jumpAlert:
            app.actions.jumpToAlert()
        case .terminal:
            let s = app.store.sessions.first { $0.status == .waiting } ?? app.store.sessions.first
            if let s { app.actions.openTerminal(s) }
        case .nextPill:
            let ids: [String?] = [nil] + app.pills.activeIds.map { Optional($0) }
            let i = ids.firstIndex(where: { $0 == app.selectedPill }) ?? 0
            app.tab = .home
            app.selectedPill = ids[(i + 1) % ids.count]
            app.actions.expand()
        case .mute:
            app.store.soundsOn.toggle()
            CharacterState.shared.emote(.bubble(app.store.soundsOn ? "🔊" : "🔇"))
        case .desktop:
            let d = DesktopBirdController.shared
            if d.isOnDesktop { d.goHome() } else { d.sendToDesktop() }
        case .wardrobe:
            WardrobePopup.show()
        case .listen:
            VoiceEngine.shared.listenNow()
        }
    }

    // MARK: - Carbon

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            Task { @MainActor in
                let all = ShortcutAction.allCases
                if index < all.count { HotKeyCenter.shared.perform(all[index]) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func registerAll() {
        unregisterAll()
        guard recording == nil else { return }
        for (i, action) in ShortcutAction.allCases.enumerated() {
            guard let key = bindings[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(i))
            if RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    /// Kayıt: eylem → [tuş, değiştirici]; boş dizi "kısayol yok" demektir. Kayıtsız eylem varsayılanı kullanır.
    private func load() {
        let saved = UserDefaults.standard.dictionary(forKey: "kisayollar") as? [String: [Int]] ?? [:]
        var b: [ShortcutAction: HotKey] = [:]
        for a in ShortcutAction.allCases {
            if let v = saved[a.rawValue] {
                if v.count == 2 { b[a] = HotKey(keyCode: UInt32(v[0]), modifiers: UInt32(v[1])) }
            } else {
                b[a] = a.defaultKey
            }
        }
        bindings = b
    }

    private func save() {
        var d: [String: [Int]] = [:]
        for a in ShortcutAction.allCases {
            if let k = bindings[a] { d[a.rawValue] = [Int(k.keyCode), Int(k.modifiers)] } else { d[a.rawValue] = [] }
        }
        UserDefaults.standard.set(d, forKey: "kisayollar")
    }
}

// MARK: - Ayarlar

struct ShortcutSettings: View {
    @ObservedObject var center: HotKeyCenter

    var body: some View {
        SettingsGroup(title: "Genel kısayollar",
                      footer: "Kısayola tıkla, sonra yeni tuşları bas. En az bir ⌘, ⌃ ya da ⌥ gerekir. Esc vazgeçer, ⌫ kısayolu siler.") {
            ForEach(ShortcutAction.allCases) { a in
                HStack {
                    Text(a.title)
                    Spacer()
                    ShortcutRecorder(action: a, center: center)
                }
            }
        }
        Button("Varsayılanlara dön") { center.resetDefaults() }
    }
}

struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject var center: HotKeyCenter
    @State private var monitor: Any?

    private var isRecording: Bool { center.recording == action }

    var body: some View {
        Button {
            isRecording ? stop() : begin()
        } label: {
            Text(isRecording ? "Tuşla…" : (center.bindings[action]?.display ?? "Yok"))
                .font(.system(.body, design: .rounded).monospacedDigit())
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func begin() {
        stop()
        center.recording = action
        center.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                center.recording = nil
                center.set(action, nil)
                stop()
            default:
                let mods = HotKey.carbonModifiers(e.modifierFlags)
                guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else { NSSound.beep(); return nil }
                center.recording = nil
                center.set(action, HotKey(keyCode: UInt32(e.keyCode), modifiers: mods))
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if center.recording == action {
            center.recording = nil
            center.suspend(false)
        }
    }
}

/// Tuş kodlarının okunur adları (ABD düzeni; kısayol gösterimi için yeterli).
enum KeyNames {
    static func name(_ code: UInt32) -> String {
        let table: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Boşluk", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Minus: "-",
            kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`", kVK_ANSI_Backslash: "\\",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return table[Int(code)] ?? "#\(code)"
    }
}
