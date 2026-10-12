import SwiftUI

/// Fare konumu; kuşun gözleri bunu izler. Her karede okunur, yayınlanmaz (gereksiz yeniden çizim olmasın).
enum MouseTracker {
    nonisolated(unsafe) static var location: CGPoint = .zero
    nonisolated(unsafe) static var birdAnchor: CGPoint = .zero
}

/// Serçe: notch'a tünemiş tombul bir kuş. Tamamen çizimle üretilir, görsel dosyası yok.
struct Bird: View {
    var mood: Mood
    var size: CGFloat

    private static let feather = Color(red: 0.60, green: 0.42, blue: 0.27)
    private static let cap = Color(red: 0.42, green: 0.28, blue: 0.18)
    private static let belly = Color(red: 0.93, green: 0.86, blue: 0.75)
    private static let wing = Color(red: 0.47, green: 0.32, blue: 0.20)
    private static let beak = Color(red: 0.98, green: 0.72, blue: 0.30)

    var body: some View {
        TimelineView(.animation(minimumInterval: mood == .sleep ? 1.0 / 12 : 1.0 / 40)) { tl in
            Canvas { ctx, sz in
                draw(&ctx, sz.width, tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: size, height: size)
    }

    private func draw(_ ctx: inout GraphicsContext, _ s: CGFloat, _ t: Double) {
        // Hareket: nefes, iş başında sekme, alarmda zıplama, bitince sevinç.
        var dy = 0.0, tilt = 0.0, squash = 1 + 0.025 * sin(t * 2.2)
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
        case .sleep:
            squash = 1 + 0.035 * sin(t * 1.2)
        case .idle:
            break
        }

        ctx.translateBy(x: s / 2, y: s * (0.55 + dy))
        ctx.rotate(by: .radians(tilt))
        ctx.scaleBy(x: s * (2 - squash), y: s * squash)
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
        ctx.fill(tail, with: .color(Self.cap))

        // Gövde, karın, başlık
        let body = oval(0.5, 0.58, 0.74, 0.70)
        ctx.fill(body, with: .color(Self.feather))
        var inner = ctx
        inner.clip(to: body)
        inner.fill(oval(0.60, 0.74, 0.52, 0.46), with: .color(Self.belly))
        inner.fill(oval(0.50, 0.26, 0.62, 0.30), with: .color(Self.cap))
        inner.fill(oval(0.66, 0.56, 0.24, 0.13), with: .color(.white.opacity(0.9)))

        // Kanat
        var w = ctx
        w.translateBy(x: 0.40, y: 0.62)
        w.rotate(by: .radians(mood == .happy ? -0.5 + sin(t * 14) * 0.3 : -0.25))
        w.fill(oval(0, 0, 0.36, 0.22), with: .color(Self.wing))
        w.stroke(Path { p in p.move(to: CGPoint(x: -0.10, y: 0.0)); p.addLine(to: CGPoint(x: 0.10, y: 0.0)) },
                 with: .color(Self.cap), lineWidth: 0.025)

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
        if mood == .sleep || mood == .happy || blink {
            let up = mood == .happy
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: eye.x - 0.065, y: eye.y))
                p.addQuadCurve(to: CGPoint(x: eye.x + 0.065, y: eye.y),
                               control: CGPoint(x: eye.x, y: eye.y + (up ? -0.07 : 0.05)))
            }, with: .color(.black), style: StrokeStyle(lineWidth: 0.035, lineCap: .round))
        } else {
            let m = MouseTracker.location, a = MouseTracker.birdAnchor
            let dx = max(-1, min(1, (m.x - a.x) / 300)), dyy = max(-1, min(1, (a.y - m.y) / 200))
            ctx.fill(oval(eye.x, eye.y, 0.15, 0.15), with: .color(.white))
            let px = eye.x + dx * 0.03, py = eye.y + dyy * 0.03
            ctx.fill(oval(px, py, 0.10, 0.10), with: .color(.black))
            ctx.fill(oval(px + 0.02, py - 0.025, 0.035, 0.035), with: .color(.white))
        }
    }
}
