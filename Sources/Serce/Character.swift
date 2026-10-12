import AppKit
import SwiftUI

/// Kuşun giyebileceği kıyafetler. Hepsi Canvas'ta çizilir (OutfitDrawing.swift).
enum Outfit: String, CaseIterable, Identifiable {
    case none, beanie, scarf, sunglasses, crown, headphones, bowtie, partyHat, fez, santa, flower

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Sade Pepe"
        case .beanie: "Bere"
        case .scarf: "Atkı"
        case .sunglasses: "Güneş gözlüğü"
        case .crown: "Taç"
        case .headphones: "Kulaklık"
        case .bowtie: "Papyon"
        case .partyHat: "Parti şapkası"
        case .fez: "Fes"
        case .santa: "Yılbaşı şapkası"
        case .flower: "Çiçek"
        }
    }

    /// Kullanıcı seçim yapmadıysa mevsime göre giyilen kıyafet.
    static func seasonal(_ date: Date = Date()) -> Outfit {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        let m = c.month ?? 1, d = c.day ?? 1
        if (m == 12 && d >= 20) || (m == 1 && d <= 2) { return .santa }
        switch m {
        case 12, 1, 2: return .scarf
        case 4, 5: return .flower
        case 6, 7, 8: return .sunglasses
        default: return .none
        }
    }
}

/// Mood'dan bağımsız, kısa süreli tepkiler: dürtülünce sinirlenme, ısrarda baş dönmesi, açılışta selam, baloncuklar.
enum BirdEmote: Equatable {
    case annoyed, dizzy, greet, hop
    case bubble(String)

    var duration: Double {
        switch self {
        case .annoyed: 1.3
        case .dizzy: 2.6
        case .greet: 2.2
        case .hop: 0.75
        case .bubble: 2.0
        }
    }
}

/// Her karede okunan ayna: tüm kuşlar (notch, kartlar, masaüstü) aynı kıyafeti ve aynı tepkiyi buradan alır.
enum CharacterMirror {
    nonisolated(unsafe) static var outfit: Outfit = .none
    nonisolated(unsafe) static var emote: BirdEmote?
    nonisolated(unsafe) static var emoteStart: Double = 0

    /// Şu an oynayan tepki ve başlangıcından bu yana geçen süre.
    static func current(at t: Double) -> (BirdEmote, Double)? {
        guard let e = emote else { return nil }
        let elapsed = t - emoteStart
        return elapsed >= 0 && elapsed < e.duration ? (e, elapsed) : nil
    }
}

@MainActor final class CharacterState: ObservableObject {
    static let shared = CharacterState()

    /// Kullanıcının seçtiği kıyafet; nil ise mevsime göre.
    @Published private(set) var chosen: Outfit?
    @Published private(set) var outfit: Outfit = .none
    /// Her tepkide artar; kuşlar yalnızca bu değişince kısa süre canlanır, geri kalan zamanda hareketsizdir.
    @Published private(set) var emoteCount = 0
    private var dayTimer: Timer?

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "kiyafet"), let o = Outfit(rawValue: raw) { chosen = o }
        refresh()
        // Gün dönünce mevsimlik kıyafet değişebilir.
        dayTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in CharacterState.shared.refresh() }
        }
    }

    func choose(_ o: Outfit?) {
        chosen = o
        UserDefaults.standard.set(o?.rawValue, forKey: "kiyafet")
        refresh()
        emote(.bubble(o == nil ? "🍂" : "✨"))
    }

    private func refresh() {
        outfit = chosen ?? Outfit.seasonal()
        CharacterMirror.outfit = outfit
    }

    func emote(_ e: BirdEmote) {
        CharacterMirror.emote = e
        CharacterMirror.emoteStart = Date().timeIntervalSinceReferenceDate
        emoteCount += 1
    }

    /// Sevme: tıklayınca bir kez zıplar.
    func poke() {
        emote(.hop)
        SoundEngine.shared.play(.poke)
    }

    func greet() {
        emote(.greet)
        SoundEngine.shared.play(.greet)
    }
}

// MARK: - Gardırop menüsü

/// Sağ tık menüsü (SwiftUI contextMenu).
struct WardrobeMenu: View {
    @ObservedObject var character = CharacterState.shared

    var body: some View {
        Section("Gardırop") {
            Button {
                character.choose(nil)
            } label: {
                if character.chosen == nil { Label("Mevsime göre", systemImage: "checkmark") } else { Text("Mevsime göre") }
            }
            ForEach(Outfit.allCases) { o in
                Button {
                    character.choose(o)
                } label: {
                    if character.chosen == o { Label(o.title, systemImage: "checkmark") } else { Text(o.title) }
                }
            }
        }
        Divider()
        if DesktopBirdController.shared.isOnDesktop {
            Button("Eve dön") { DesktopBirdController.shared.goHome() }
        } else {
            Button("Masaüstüne gönder") { DesktopBirdController.shared.sendToDesktop() }
        }
    }
}

/// Kısayoldan açılan aynı menü (AppKit; fare konumunda açılır).
@MainActor enum WardrobePopup {
    @MainActor private final class Target: NSObject {
        @objc func pick(_ item: NSMenuItem) {
            let raw = item.representedObject as? String
            CharacterState.shared.choose(raw.flatMap(Outfit.init(rawValue:)))
        }
        @objc func desktop() {
            let d = DesktopBirdController.shared
            if d.isOnDesktop { d.goHome() } else { d.sendToDesktop() }
        }
    }
    private static let target = Target()

    static func show() {
        let menu = NSMenu(title: "Gardırop")
        let chosen = CharacterState.shared.chosen
        let auto = NSMenuItem(title: "Mevsime göre", action: #selector(Target.pick(_:)), keyEquivalent: "")
        auto.target = target
        auto.state = chosen == nil ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        for o in Outfit.allCases {
            let i = NSMenuItem(title: o.title, action: #selector(Target.pick(_:)), keyEquivalent: "")
            i.target = target
            i.representedObject = o.rawValue
            i.state = chosen == o ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let d = NSMenuItem(title: DesktopBirdController.shared.isOnDesktop ? "Eve dön" : "Masaüstüne gönder",
                           action: #selector(Target.desktop), keyEquivalent: "")
        d.target = target
        menu.addItem(d)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Kayıt

@MainActor enum CharacterFeature {
    static func register(_ app: AppState) {
        _ = CharacterState.shared
        SoundEngine.shared.prepareFolder()
        HotKeyCenter.shared.start(app)
        DesktopBirdController.shared.start(app)
        let r = SettingsRegistry.shared
        r.add(SettingsSection(id: "karakter", title: "Karakter", icon: "pawprint", order: 5) {
            AnyView(CharacterSettings(character: .shared))
        })
        r.add(SettingsSection(id: "kisayollar", title: "Kısayollar", icon: "keyboard", order: 30) {
            AnyView(ShortcutSettings(center: .shared))
        })
        // Açılışta selam: ada yerleştikten hemen sonra.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { CharacterState.shared.greet() }
    }
}
