import SwiftUI

/// Fare konumu; kuşun gözleri bunu izler. Her karede okunur, yayınlanmaz (gereksiz yeniden çizim olmasın).
enum MouseTracker {
    nonisolated(unsafe) static var location: CGPoint = .zero
    nonisolated(unsafe) static var birdAnchor: CGPoint = .zero
    /// Masaüstü kuşunun ekran üzerindeki merkezi.
    nonisolated(unsafe) static var desktopAnchor: CGPoint = .zero
}

/// Gözlerin neyi referans alarak imleci izleyeceği.
enum EyeAnchor { case notch, desktop, fixed }

/// Serçe: notch'a tünemiş tombul bir kuş. Tamamen çizimle üretilir, görsel dosyası yok.
struct Bird: View {
    var mood: Mood
    var size: CGFloat
    /// Pill kuşları için tüy rengi (Stripe mavisi, GitHub kırmızısı…). nil ise doğal serçe.
    var tint: Color? = nil
    /// nil ise ortak kıyafet (gardıroptan seçilen ya da mevsimlik).
    var outfit: Outfit? = nil
    /// Dürtme, sağ tık gardırop ve tepkiler bu kuşta etkin mi (notch ve masaüstü kuşu).
    var interactive = false
    var eyes: EyeAnchor = .notch
    /// Anlık görüntü için sabit tepki: (tepki, başlangıçtan bu yana geçen süre).
    var frozenEmote: (BirdEmote, Double)? = nil

    private static let baseFeather = Color(red: 0.60, green: 0.42, blue: 0.27)
    private static let baseCap = Color(red: 0.42, green: 0.28, blue: 0.18)
    private static let belly = Color(red: 0.93, green: 0.86, blue: 0.75)
    private static let baseWing = Color(red: 0.47, green: 0.32, blue: 0.20)
    private static let beak = Color(red: 0.98, green: 0.72, blue: 0.30)

    private var feather: Color { tint ?? Self.baseFeather }
    private var cap: Color { tint.map { Self.shade($0, 0.35) } ?? Self.baseCap }
    private var wing: Color { tint.map { Self.shade($0, 0.22) } ?? Self.baseWing }

    private static func shade(_ c: Color, _ amount: CGFloat) -> Color {
        Color(nsColor: NSColor(c).usingColorSpace(.sRGB)?.blended(withFraction: amount, of: .black) ?? NSColor(c))
    }

    var body: some View {
        let fps = (mood == .sleep && !interactive) ? 1.0 / 12 : 1.0 / 40
        TimelineView(.animation(minimumInterval: fps)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let emote = frozenEmote ?? (interactive ? CharacterMirror.current(at: t) : nil)
            Canvas { ctx, sz in
                draw(&ctx, sz.width, t, emote)
            }
            .overlay(alignment: .topTrailing) {
                if let text = bubbleText(emote) {
                    Text(text)
                        .font(.system(size: max(9, size * 0.22), weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, max(4, size * 0.08)).padding(.vertical, max(1, size * 0.03))
                        .background(Capsule().fill(.white))
                        .fixedSize()
                        .offset(x: size * 0.5, y: -size * 0.12)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: size, height: size)
        .modifier(BirdInteraction(enabled: interactive))
    }

    private func bubbleText(_ e: (BirdEmote, Double)?) -> String? {
        guard let e else { return nil }
        switch e.0 {
        case .bubble(let s): return s
        case .greet: return "cik!"
        default: return nil
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ s: CGFloat, _ t: Double, _ emote: (BirdEmote, Double)?) {
        // Hareket: nefes, iş başında sekme, alarmda zıplama, bitince sevinç.
        var dy = 0.0, tilt = 0.0, squash = 1 + 0.025 * sin(t * 2.2), puff = 1.0
        var wingAngle = mood == .happy ? -0.5 + sin(t * 14) * 0.3 : -0.25
        switch mood {
        case .working:
            dy = -abs(sin(t * 7)) * 0.035
            tilt = sin(t * 3.5) * 0.06
        case .alert:
            dy = -abs(sin(t * 9)) * 0.09
            tilt = sin(t * 18) * 0.05
        case .happy:
            dy = -abs(sin(t * 6)) * 0.12
            squash = 1 + 0.06 * sin(t * 12)
        case .dance:
            dy = -abs(sin(t * 4.2)) * 0.07
            tilt = sin(t * 4.2) * 0.18
            wingAngle = -0.4 + sin(t * 8.4) * 0.35
        case .sleep:
            squash = 1 + 0.035 * sin(t * 1.2)
        case .idle:
            break
        }

        // Tepkiler hareketin üstüne biner.
        var k = 0.0
        if let (e, el) = emote {
            let p = el / e.duration
            k = sin(.pi * min(1, p * 1.15))
            switch e {
            case .annoyed:
                puff = 1 + 0.10 * k
                tilt = sin(el * 42) * 0.07 * (1 - p)
                dy = 0
            case .dizzy:
                tilt = sin(el * 9) * 0.26 * (1 - p * 0.5)
                dy = 0
            case .greet:
                dy = -abs(sin(el * 7)) * 0.10
                wingAngle = -1.05 + sin(el * 24) * 0.55
            case .bubble:
                break
            }
        }

        ctx.translateBy(x: s / 2, y: s * (0.55 + dy))
        ctx.rotate(by: .radians(tilt))
        ctx.scaleBy(x: s * (2 - squash) * puff, y: s * squash * puff)
        ctx.translateBy(x: -0.5, y: -0.55)

        func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
            Path(ellipseIn: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h))
        }

        // Kuyruk
        var tail = Path()
        tail.move(to: CGPoint(x: 0.22, y: 0.62))
        tail.addLine(to: CGPoint(x: 0.02, y: 0.34))
        tail.addQuadCurve(to: CGPoint(x: 0.13, y: 0.30), control: CGPoint(x: 0.06, y: 0.27))
        tail.addLine(to: CGPoint(x: 0.30, y: 0.50))
        tail.closeSubpath()
        ctx.fill(tail, with: .color(cap))

        let annoyed: Bool = { if case .annoyed? = emote?.0 { return true }; return false }()
        let greeting: Bool = { if case .greet? = emote?.0 { return true }; return false }()
        if annoyed { OutfitArt.annoyedSpikes(&ctx, feather: cap, k: k) }

        // Gövde, karın, başlık
        let body = oval(0.5, 0.58, 0.74, 0.70)
        ctx.fill(body, with: .color(feather))
        var inner = ctx
        inner.clip(to: body)
        inner.fill(oval(0.60, 0.74, 0.52, 0.46), with: .color(Self.belly))
        inner.fill(oval(0.50, 0.26, 0.62, 0.30), with: .color(cap))
        inner.fill(oval(0.66, 0.56, 0.24, 0.13), with: .color(.white.opacity(0.9)))

        // Kanat
        var w = ctx
        w.translateBy(x: 0.40, y: 0.62)
        w.rotate(by: .radians(wingAngle))
        w.fill(oval(0, 0, 0.36, 0.22), with: .color(wing))
        w.stroke(Path { p in p.move(to: CGPoint(x: -0.10, y: 0.0)); p.addLine(to: CGPoint(x: 0.10, y: 0.0)) },
                 with: .color(cap), lineWidth: 0.025)

        // Gaga ve göğüsteki küçük siyah önlük
        var beak = Path()
        beak.move(to: CGPoint(x: 0.82, y: 0.46))
        beak.addLine(to: CGPoint(x: 0.97, y: 0.51))
        beak.addLine(to: CGPoint(x: 0.82, y: 0.56))
        beak.closeSubpath()
        ctx.fill(beak, with: .color(Self.beak))
        ctx.fill(oval(0.79, 0.645, 0.11, 0.07), with: .color(Color(red: 0.16, green: 0.11, blue: 0.08)))

        // Göz: fareyi izler, ara sıra kırpar; uykuda ve sevinçte çizgi olur.
        let eye = CGPoint(x: 0.64, y: 0.44)
        let blink = fmod(t, 3.9) < 0.12
        if case .dizzy? = emote?.0 {
            OutfitArt.dizzy(&ctx, eye: eye, t: t)
        } else if greeting || (emote == nil && (mood == .sleep || mood == .happy || blink)) {
            let up = mood == .happy || greeting
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: eye.x - 0.065, y: eye.y))
                p.addQuadCurve(to: CGPoint(x: eye.x + 0.065, y: eye.y),
                               control: CGPoint(x: eye.x, y: eye.y + (up ? -0.07 : 0.05)))
            }, with: .color(.black), style: StrokeStyle(lineWidth: 0.035, lineCap: .round))
        } else {
            var dx = 0.0, dyy = 0.0
            if eyes != .fixed {
                let m = MouseTracker.location
                let a = eyes == .desktop ? MouseTracker.desktopAnchor : MouseTracker.birdAnchor
                dx = max(-1, min(1, (m.x - a.x) / 300))
                dyy = max(-1, min(1, (a.y - m.y) / 200))
            }
            ctx.fill(oval(eye.x, eye.y, 0.15, 0.15), with: .color(.white))
            let px = eye.x + dx * 0.03, py = eye.y + dyy * 0.03
            ctx.fill(oval(px, py, 0.10, 0.10), with: .color(.black))
            ctx.fill(oval(px + 0.02, py - 0.025, 0.035, 0.035), with: .color(.white))
        }

        if annoyed { OutfitArt.annoyedFace(&ctx, k: k) }
        OutfitArt.draw(outfit ?? CharacterMirror.outfit, in: &ctx)
    }
}

/// Etkileşimli kuş: tıklayınca dürtülür, sağ tıkta gardırop açılır.
private struct BirdInteraction: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .onTapGesture { CharacterState.shared.poke() }
                .contextMenu { WardrobeMenu() }
        } else {
            content
        }
    }
}
