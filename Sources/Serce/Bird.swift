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

/// Pepe: çentikte oturan bir Akbaş (çivili tasmalı, kıvrık kuyruklu), yandan. Tamamen çizimle üretilir, görsel dosyası yok.
struct Bird: View {
    var mood: Mood
    var size: CGFloat
    /// Pill karakterleri için tüy rengi (Stripe moru, GitHub kırmızısı…). nil ise beyaz Pepe.
    var tint: Color? = nil
    /// nil ise ortak kıyafet (gardıroptan seçilen ya da mevsimlik).
    var outfit: Outfit? = nil
    /// Dürtme, sağ tık gardırop ve tepkiler bu kuşta etkin mi (notch ve masaüstü kuşu).
    var interactive = false
    var eyes: EyeAnchor = .notch
    /// Anlık görüntü için sabit tepki: (tepki, başlangıçtan bu yana geçen süre).
    var frozenEmote: (BirdEmote, Double)? = nil

    // Akbaş: krem-beyaz kısa tüy, biraz daha koyu krem kulaklar.
    private static let baseFur = Color(red: 0.99, green: 0.975, blue: 0.94)
    private static let baseShade = Color(red: 0.91, green: 0.88, blue: 0.83)
    private static let baseEar = Color(red: 0.94, green: 0.88, blue: 0.79)
    private static let baseLine = Color(red: 0.60, green: 0.56, blue: 0.52)
    private static let nose = Color(red: 0.12, green: 0.10, blue: 0.10)
    private static let collar = Color(red: 0.32, green: 0.21, blue: 0.15)
    private static let stud = Color(red: 0.82, green: 0.84, blue: 0.87)

    private var fur: Color { tint ?? Self.baseFur }
    private var furShade: Color { tint.map { Self.shade($0, 0.14) } ?? Self.baseShade }
    private var ear: Color { tint.map { Self.shade($0, 0.28) } ?? Self.baseEar }
    private var line: Color { tint.map { Self.shade($0, 0.45) } ?? Self.baseLine }

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
        case .greet: return "hav!"
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

        let annoyed: Bool = { if case .annoyed? = emote?.0 { return true }; return false }()
        let greeting: Bool = { if case .greet? = emote?.0 { return true }; return false }()
        // Oturan Akbaş, yandan (sağa bakıyor). Birim kare: baş sağ üstte, kalça sol altta, ön bacaklar dik.
        let outline = StrokeStyle(lineWidth: 0.014, lineCap: .round, lineJoin: .round)
        let worn = outfit ?? CharacterMirror.outfit
        func stroked(_ p: Path, _ c: inout GraphicsContext, fill: Color) {
            c.fill(p, with: .color(fill))
            c.stroke(p, with: .color(line), style: outline)
        }

        // Kuyruk: kalçanın arkasından sırta doğru kıvrık; sevinçte hızlı sallanır.
        let wagSpeed: Double = greeting || mood == .happy ? 18 : mood == .working || mood == .dance ? 9 : mood == .sleep ? 0 : 3
        var tailCtx = ctx
        tailCtx.translateBy(x: 0.17, y: 0.76)
        tailCtx.rotate(by: .radians(annoyed ? 0.2 : sin(t * wagSpeed) * 0.25))
        var curl = Path()
        curl.move(to: CGPoint(x: 0.03, y: 0.02))
        curl.addCurve(to: CGPoint(x: -0.06, y: -0.26), control1: CGPoint(x: -0.10, y: -0.02), control2: CGPoint(x: -0.13, y: -0.20))
        curl.addCurve(to: CGPoint(x: 0.05, y: -0.22), control1: CGPoint(x: -0.01, y: -0.32), control2: CGPoint(x: 0.06, y: -0.29))
        tailCtx.stroke(curl, with: .color(line), style: StrokeStyle(lineWidth: 0.072, lineCap: .round, lineJoin: .round))
        tailCtx.stroke(curl, with: .color(fur), style: StrokeStyle(lineWidth: 0.046, lineCap: .round, lineJoin: .round))

        // Uzaktaki ön bacak (bir ton gölgeli)
        let farLeg = Path(roundedRect: CGRect(x: 0.53, y: 0.60, width: 0.10, height: 0.34), cornerRadius: 0.05)
        stroked(farLeg, &ctx, fill: furShade)
        stroked(oval(0.59, 0.94, 0.12, 0.05), &ctx, fill: furShade)

        // Gövde: boyundan kalçaya inen sırt, yere oturmuş arka, öne dolgun göğüs.
        var body = Path()
        body.move(to: CGPoint(x: 0.50, y: 0.36))
        body.addCurve(to: CGPoint(x: 0.17, y: 0.78), control1: CGPoint(x: 0.36, y: 0.42), control2: CGPoint(x: 0.18, y: 0.55))
        body.addCurve(to: CGPoint(x: 0.34, y: 0.955), control1: CGPoint(x: 0.16, y: 0.90), control2: CGPoint(x: 0.22, y: 0.955))
        body.addLine(to: CGPoint(x: 0.62, y: 0.955))
        body.addCurve(to: CGPoint(x: 0.75, y: 0.50), control1: CGPoint(x: 0.74, y: 0.80), control2: CGPoint(x: 0.79, y: 0.62))
        body.addLine(to: CGPoint(x: 0.66, y: 0.38))
        body.closeSubpath()
        ctx.fill(body, with: .color(fur))
        var inner = ctx
        inner.clip(to: body)
        inner.fill(oval(0.30, 0.98, 0.50, 0.20), with: .color(furShade))
        ctx.stroke(body, with: .color(line), style: outline)

        // Arka bacak: oturmuş kalça ve öne uzanan arka pati.
        var thigh = Path()
        thigh.move(to: CGPoint(x: 0.24, y: 0.64))
        thigh.addCurve(to: CGPoint(x: 0.47, y: 0.90), control1: CGPoint(x: 0.40, y: 0.60), control2: CGPoint(x: 0.50, y: 0.76))
        ctx.stroke(thigh, with: .color(line), style: outline)
        stroked(oval(0.45, 0.945, 0.15, 0.055), &ctx, fill: fur)

        // Yakın ön bacak
        let leg = Path(roundedRect: CGRect(x: 0.615, y: 0.56, width: 0.115, height: 0.38), cornerRadius: 0.055)
        stroked(leg, &ctx, fill: fur)
        stroked(oval(0.69, 0.94, 0.15, 0.06), &ctx, fill: fur)
        for dx in [-0.022, 0.012] {
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0.685 + dx + 0.02, y: 0.925)); p.addLine(to: CGPoint(x: 0.685 + dx + 0.02, y: 0.945)) },
                       with: .color(line), style: StrokeStyle(lineWidth: 0.009, lineCap: .round))
        }

        // Çivili tasma: boynun etrafında.
        if worn != .scarf {
            var collar = Path()
            collar.move(to: CGPoint(x: 0.50, y: 0.43))
            collar.addQuadCurve(to: CGPoint(x: 0.745, y: 0.47), control: CGPoint(x: 0.62, y: 0.55))
            var neck = ctx
            neck.clip(to: body)
            neck.stroke(collar, with: .color(Self.collar), style: StrokeStyle(lineWidth: 0.045, lineCap: .round))
            for u in stride(from: 0.15, through: 0.9, by: 0.15) {
                let a = CGPoint(x: 0.50, y: 0.43), c = CGPoint(x: 0.62, y: 0.55), b = CGPoint(x: 0.745, y: 0.47)
                let px = (1 - u) * (1 - u) * a.x + 2 * (1 - u) * u * c.x + u * u * b.x
                let py = (1 - u) * (1 - u) * a.y + 2 * (1 - u) * u * c.y + u * u * b.y
                var spike = Path()
                spike.move(to: CGPoint(x: px - 0.013, y: py + 0.012))
                spike.addLine(to: CGPoint(x: px, y: py + 0.045))
                spike.addLine(to: CGPoint(x: px + 0.013, y: py + 0.012))
                spike.closeSubpath()
                neck.fill(spike, with: .color(Self.stud))
                neck.fill(oval(px, py, 0.016, 0.016), with: .color(Self.stud))
            }
        }

        if annoyed {
            var hc = headSpace(ctx)
            OutfitArt.annoyedSpikes(&hc, feather: ear, k: k)
        }

        // Baş: geniş kafatası + uzun, köşeli ağız.
        let skull = oval(0.60, 0.29, 0.34, 0.30)
        stroked(skull, &ctx, fill: fur)
        let muzzle = Path(roundedRect: CGRect(x: 0.70, y: 0.255, width: 0.235, height: 0.155), cornerRadius: 0.07)
        ctx.fill(muzzle, with: .color(fur))
        var mOut = ctx
        mOut.clip(to: skull, options: .inverse)
        mOut.stroke(muzzle, with: .color(line), style: outline)
        ctx.fill(oval(0.77, 0.265, 0.09, 0.025), with: .color(furShade.opacity(0.7)))
        if mood == .happy || greeting {
            var mouth = Path()
            mouth.move(to: CGPoint(x: 0.79, y: 0.375))
            mouth.addQuadCurve(to: CGPoint(x: 0.915, y: 0.37), control: CGPoint(x: 0.85, y: 0.46))
            mouth.closeSubpath()
            ctx.fill(mouth, with: .color(Color(red: 0.25, green: 0.10, blue: 0.11)))
            ctx.fill(oval(0.855, 0.425, 0.05, 0.065), with: .color(Color(red: 1.0, green: 0.50, blue: 0.58)))
        } else {
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0.905, y: 0.32))
                p.addLine(to: CGPoint(x: 0.90, y: 0.365))
                p.addQuadCurve(to: CGPoint(x: 0.77, y: 0.375), control: CGPoint(x: 0.85, y: 0.40))
            }, with: .color(Self.nose), style: StrokeStyle(lineWidth: 0.013, lineCap: .round))
        }
        ctx.fill(Path(roundedRect: CGRect(x: 0.875, y: 0.258, width: 0.065, height: 0.058), cornerRadius: 0.025), with: .color(Self.nose))
        ctx.fill(oval(0.895, 0.271, 0.025, 0.013), with: .color(.white.opacity(0.65)))
        ctx.fill(oval(0.70, 0.36, 0.06, 0.035), with: .color(Color(red: 1.0, green: 0.62, blue: 0.62).opacity(0.3)))

        // Sarkık üçgen kulak: başın tepesinden yanağa iner; sevinçte sallanır, selamda kalkar.
        var e = ctx
        e.translateBy(x: 0.555, y: 0.17)
        e.rotate(by: .radians(0.18 + (wingAngle + 0.25) * 0.5))
        var earPath = Path()
        earPath.move(to: CGPoint(x: -0.06, y: 0.01))
        earPath.addQuadCurve(to: CGPoint(x: 0.055, y: 0.0), control: CGPoint(x: -0.005, y: -0.04))
        earPath.addQuadCurve(to: CGPoint(x: 0.0, y: 0.19), control: CGPoint(x: 0.06, y: 0.13))
        earPath.addQuadCurve(to: CGPoint(x: -0.06, y: 0.01), control: CGPoint(x: -0.055, y: 0.145))
        e.fill(earPath, with: .color(ear))
        e.stroke(earPath, with: .color(Self.shade(ear, 0.22)), style: outline)

        // Kaş
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: 0.635, y: 0.215 - (mood == .alert ? 0.015 : 0)))
            p.addQuadCurve(to: CGPoint(x: 0.70, y: 0.212 - (mood == .alert ? 0.015 : 0)), control: CGPoint(x: 0.665, y: 0.195))
        }, with: .color(Self.shade(ear, 0.18)), style: StrokeStyle(lineWidth: 0.014, lineCap: .round))

        // Göz: badem biçimli, koyu kahve, siyah çerçeveli; fareyi izler, ara sıra kırpar; uykuda ve sevinçte çizgi olur.
        let eye = CGPoint(x: 0.67, y: 0.265)
        let blink = fmod(t, 3.9) < 0.12
        if case .dizzy? = emote?.0 {
            var hc = headSpace(ctx)
            OutfitArt.dizzy(&hc, eye: Self.oldEye, t: t)
        } else if greeting || (emote == nil && (mood == .sleep || mood == .happy || blink)) {
            let up = mood == .happy || greeting
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: eye.x - 0.035, y: eye.y))
                p.addQuadCurve(to: CGPoint(x: eye.x + 0.035, y: eye.y),
                               control: CGPoint(x: eye.x, y: eye.y + (up ? -0.045 : 0.03)))
            }, with: .color(Self.nose), style: StrokeStyle(lineWidth: 0.02, lineCap: .round))
        } else {
            var dx = 0.0, dyy = 0.0
            if eyes != .fixed {
                let m = MouseTracker.location
                let a = eyes == .desktop ? MouseTracker.desktopAnchor : MouseTracker.birdAnchor
                dx = max(-1, min(1, (m.x - a.x) / 300))
                dyy = max(-1, min(1, (a.y - m.y) / 200))
            }
            ctx.fill(oval(eye.x, eye.y, 0.075, 0.072), with: .color(Self.nose))
            let px = eye.x + dx * 0.01, py = eye.y + dyy * 0.01
            ctx.fill(oval(px, py, 0.056, 0.056), with: .color(Color(red: 0.30, green: 0.19, blue: 0.12)))
            ctx.fill(oval(px, py, 0.032, 0.032), with: .color(Self.nose))
            ctx.fill(oval(px + 0.013, py - 0.014, 0.023, 0.023), with: .color(.white))
            ctx.fill(oval(px - 0.013, py + 0.015, 0.009, 0.009), with: .color(.white.opacity(0.8)))
        }

        // Kıyafetler ve tepkiler eski tombul karakterin koordinatlarında çizilir; baş ve boyna taşınır.
        if annoyed {
            var hc = headSpace(ctx)
            OutfitArt.annoyedFace(&hc, k: k)
        }
        if OutfitArt.isNeck(worn) {
            var nc = ctx
            nc.translateBy(x: 0.625, y: 0.49)
            nc.scaleBy(x: 0.5, y: 0.5)
            nc.translateBy(x: -0.60, y: -0.75)
            OutfitArt.draw(worn, in: &nc)
        } else {
            var hc = headSpace(ctx)
            OutfitArt.draw(worn, in: &hc)
        }
    }

    /// Eski karakterin göz noktası; kıyafet çizimleri buna göre yazıldı.
    private static let oldEye = CGPoint(x: 0.64, y: 0.44)

    /// Kıyafet/tepki koordinatlarını (eski tombul baş) yeni başa taşır.
    private func headSpace(_ ctx: GraphicsContext) -> GraphicsContext {
        var c = ctx
        c.translateBy(x: 0.665, y: 0.265)
        c.scaleBy(x: 0.62, y: 0.62)
        c.translateBy(x: -Self.oldEye.x, y: -Self.oldEye.y)
        return c
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
