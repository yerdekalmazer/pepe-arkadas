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

/// Pepe: çentikte yaşayan tombul bir Akbaş yavrusu (çivili tasmalı, kıvrık kuyruklu). Tamamen çizimle üretilir, görsel dosyası yok.
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
        let outline = StrokeStyle(lineWidth: 0.016, lineCap: .round, lineJoin: .round)

        // Kuyruk: Akbaş gibi sırtın üstüne kıvrık; sevinçte ve selamda hızlı sallanır.
        let wagSpeed: Double = greeting || mood == .happy ? 18 : mood == .working || mood == .dance ? 9 : mood == .sleep ? 0 : 3
        var tailCtx = ctx
        tailCtx.translateBy(x: 0.22, y: 0.52)
        tailCtx.rotate(by: .radians((annoyed ? 0.15 : sin(t * wagSpeed) * 0.22) - (mood == .sleep ? 0.0 : 0.05)))
        var curl = Path()
        curl.move(to: CGPoint(x: 0.06, y: 0.04))
        curl.addCurve(to: CGPoint(x: -0.10, y: -0.20), control1: CGPoint(x: -0.10, y: 0.02), control2: CGPoint(x: -0.17, y: -0.12))
        curl.addCurve(to: CGPoint(x: 0.0, y: -0.15), control1: CGPoint(x: -0.05, y: -0.27), control2: CGPoint(x: 0.03, y: -0.22))
        tailCtx.stroke(curl, with: .color(line), style: StrokeStyle(lineWidth: 0.075, lineCap: .round, lineJoin: .round))
        tailCtx.stroke(curl, with: .color(fur), style: StrokeStyle(lineWidth: 0.047, lineCap: .round, lineJoin: .round))

        // Arkadaki kulak: başın tepesinden azıcık görünen üçgen.
        var farEar = ctx
        farEar.translateBy(x: 0.66, y: 0.255)
        farEar.rotate(by: .radians(-0.35 + (mood == .alert ? -0.25 : 0)))
        var fe = Path()
        fe.move(to: CGPoint(x: -0.06, y: 0.03))
        fe.addQuadCurve(to: CGPoint(x: 0.05, y: 0.02), control: CGPoint(x: 0.0, y: -0.05))
        fe.addQuadCurve(to: CGPoint(x: 0.03, y: 0.12), control: CGPoint(x: 0.07, y: 0.09))
        fe.closeSubpath()
        farEar.fill(fe, with: .color(Self.shade(ear, 0.06)))
        farEar.stroke(fe, with: .color(line), style: outline)

        if annoyed { OutfitArt.annoyedSpikes(&ctx, feather: ear, k: k) }

        // Gövde ve geniş baş tek tombul parça; altta hafif gölge, boyunda çivili tasma.
        let body = oval(0.5, 0.58, 0.74, 0.70)
        ctx.fill(body, with: .color(fur))
        var inner = ctx
        inner.clip(to: body)
        inner.fill(oval(0.36, 0.90, 0.80, 0.34), with: .color(furShade))
        inner.fill(oval(0.44, 0.33, 0.30, 0.15), with: .color(.white.opacity(tint == nil ? 0.7 : 0.18)))
        let wearsCollar = (outfit ?? CharacterMirror.outfit) != .scarf
        // Tasma eğrisi: (0.30,0.66) → (0.90,0.70), kontrol (0.58,0.84).
        func collarPoint(_ u: Double) -> (CGPoint, CGVector) {
            let a = CGPoint(x: 0.30, y: 0.66), c = CGPoint(x: 0.58, y: 0.84), b = CGPoint(x: 0.90, y: 0.70)
            let x = (1 - u) * (1 - u) * a.x + 2 * (1 - u) * u * c.x + u * u * b.x
            let y = (1 - u) * (1 - u) * a.y + 2 * (1 - u) * u * c.y + u * u * b.y
            let dx = 2 * (1 - u) * (c.x - a.x) + 2 * u * (b.x - c.x), dy = 2 * (1 - u) * (c.y - a.y) + 2 * u * (b.y - c.y)
            let l = max(0.0001, (dx * dx + dy * dy).squareRoot())
            return (CGPoint(x: x, y: y), CGVector(dx: -dy / l, dy: dx / l))
        }
        if wearsCollar {
            var collar = Path()
            collar.move(to: CGPoint(x: 0.30, y: 0.66))
            collar.addQuadCurve(to: CGPoint(x: 0.90, y: 0.70), control: CGPoint(x: 0.58, y: 0.84))
            inner.stroke(collar, with: .color(Self.collar), style: StrokeStyle(lineWidth: 0.06, lineCap: .round))
            // Gümüş çiviler: tasmadan dışa (aşağı) bakan küçük üçgenler.
            for u in stride(from: 0.12, through: 0.9, by: 0.13) {
                let (p, n) = collarPoint(u)
                let tx = -n.dy, ty = n.dx
                var spike = Path()
                spike.move(to: CGPoint(x: p.x + n.dx * 0.02 + tx * 0.018, y: p.y + n.dy * 0.02 + ty * 0.018))
                spike.addLine(to: CGPoint(x: p.x + n.dx * 0.065, y: p.y + n.dy * 0.065))
                spike.addLine(to: CGPoint(x: p.x + n.dx * 0.02 - tx * 0.018, y: p.y + n.dy * 0.02 - ty * 0.018))
                spike.closeSubpath()
                inner.fill(spike, with: .color(Self.stud))
                inner.fill(oval(p.x, p.y, 0.022, 0.022), with: .color(Self.stud))
            }
        }
        ctx.stroke(body, with: .color(line), style: outline)

        // Ön patiler: iri, sağlam.
        for x in [0.49, 0.70] {
            let paw = oval(x, 0.915, 0.19, 0.10)
            ctx.fill(paw, with: .color(fur))
            ctx.stroke(paw, with: .color(line), style: outline)
            for dx in [-0.03, 0.0, 0.03] {
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x + dx, y: 0.89)); p.addLine(to: CGPoint(x: x + dx, y: 0.91)) },
                           with: .color(line), style: StrokeStyle(lineWidth: 0.011, lineCap: .round))
            }
        }

        // Ağız: uzun, köşeli, güçlü bir burun; çizgisi yalnız gövdenin dışında.
        let muzzle = Path(roundedRect: CGRect(x: 0.70, y: 0.465, width: 0.29, height: 0.20), cornerRadius: 0.085)
        ctx.fill(muzzle, with: .color(fur))
        var mOut = ctx
        mOut.clip(to: body, options: .inverse)
        mOut.stroke(muzzle, with: .color(line), style: outline)
        // Burun köprüsünde hafif krem gölge (stop).
        ctx.fill(oval(0.80, 0.475, 0.12, 0.035), with: .color(furShade.opacity(0.7)))
        let happyMouth = mood == .happy || greeting
        if happyMouth {
            var mouth = Path()
            mouth.move(to: CGPoint(x: 0.82, y: 0.605))
            mouth.addQuadCurve(to: CGPoint(x: 0.965, y: 0.60), control: CGPoint(x: 0.90, y: 0.72))
            mouth.closeSubpath()
            ctx.fill(mouth, with: .color(Color(red: 0.25, green: 0.10, blue: 0.11)))
            ctx.fill(oval(0.895, 0.665, 0.065, 0.075), with: .color(Color(red: 1.0, green: 0.50, blue: 0.58)))
        } else {
            // Siyah dudak çizgisi: burundan aşağı, sonra geriye doğru uzun.
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0.955, y: 0.535))
                p.addLine(to: CGPoint(x: 0.95, y: 0.595))
                p.addQuadCurve(to: CGPoint(x: 0.80, y: 0.605), control: CGPoint(x: 0.89, y: 0.635))
            }, with: .color(Self.nose), style: StrokeStyle(lineWidth: 0.015, lineCap: .round))
        }
        // Burun: iri, siyah, parlak.
        ctx.fill(Path(roundedRect: CGRect(x: 0.915, y: 0.468, width: 0.08, height: 0.07), cornerRadius: 0.03), with: .color(Self.nose))
        ctx.fill(oval(0.94, 0.484, 0.03, 0.016), with: .color(.white.opacity(0.65)))

        // Hafif yanak allığı
        ctx.fill(oval(0.71, 0.60, 0.08, 0.045), with: .color(Color(red: 1.0, green: 0.62, blue: 0.62).opacity(0.3)))

        // Öndeki kulak: başın yüksek kısmından sarkan üçgen kulak; sevinçte sallanır, selamda kalkar.
        var e = ctx
        e.translateBy(x: 0.48, y: 0.255)
        e.rotate(by: .radians(0.12 + (wingAngle + 0.25) * 0.55))
        var earPath = Path()
        earPath.move(to: CGPoint(x: -0.095, y: 0.015))
        earPath.addQuadCurve(to: CGPoint(x: 0.085, y: 0.0), control: CGPoint(x: -0.005, y: -0.06))
        earPath.addQuadCurve(to: CGPoint(x: 0.0, y: 0.29), control: CGPoint(x: 0.09, y: 0.20))
        earPath.addQuadCurve(to: CGPoint(x: -0.095, y: 0.015), control: CGPoint(x: -0.085, y: 0.22))
        e.fill(earPath, with: .color(ear))
        e.stroke(earPath, with: .color(Self.shade(ear, 0.22)), style: outline)
        var earIn = e
        earIn.clip(to: earPath)
        earIn.fill(oval(0.035, 0.07, 0.07, 0.14), with: .color(Self.shade(ear, 0.06)))

        // Kaş: ciddi ama sevimli bir çoban köpeği bakışı.
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: 0.595, y: 0.375 - (mood == .alert ? 0.02 : 0)))
            p.addQuadCurve(to: CGPoint(x: 0.685, y: 0.37 - (mood == .alert ? 0.02 : 0)), control: CGPoint(x: 0.64, y: 0.345))
        }, with: .color(Self.shade(ear, 0.18)), style: StrokeStyle(lineWidth: 0.02, lineCap: .round))

        // Göz: badem biçimli, koyu kahve, siyah çerçeveli; fareyi izler, ara sıra kırpar; uykuda ve sevinçte çizgi olur.
        let eye = CGPoint(x: 0.64, y: 0.44)
        let blink = fmod(t, 3.9) < 0.12
        if case .dizzy? = emote?.0 {
            OutfitArt.dizzy(&ctx, eye: eye, t: t)
        } else if greeting || (emote == nil && (mood == .sleep || mood == .happy || blink)) {
            let up = mood == .happy || greeting
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: eye.x - 0.055, y: eye.y))
                p.addQuadCurve(to: CGPoint(x: eye.x + 0.055, y: eye.y),
                               control: CGPoint(x: eye.x, y: eye.y + (up ? -0.07 : 0.05)))
            }, with: .color(Self.nose), style: StrokeStyle(lineWidth: 0.032, lineCap: .round))
        } else {
            var dx = 0.0, dyy = 0.0
            if eyes != .fixed {
                let m = MouseTracker.location
                let a = eyes == .desktop ? MouseTracker.desktopAnchor : MouseTracker.birdAnchor
                dx = max(-1, min(1, (m.x - a.x) / 300))
                dyy = max(-1, min(1, (a.y - m.y) / 200))
            }
            ctx.fill(oval(eye.x, eye.y, 0.118, 0.115), with: .color(Self.nose))
            let px = eye.x + dx * 0.015, py = eye.y + dyy * 0.015
            ctx.fill(oval(px, py, 0.088, 0.088), with: .color(Color(red: 0.30, green: 0.19, blue: 0.12)))
            ctx.fill(oval(px, py, 0.05, 0.05), with: .color(Self.nose))
            ctx.fill(oval(px + 0.02, py - 0.022, 0.036, 0.036), with: .color(.white))
            ctx.fill(oval(px - 0.02, py + 0.024, 0.014, 0.014), with: .color(.white.opacity(0.8)))
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
