import SwiftUI

/// Kıyafet ve tepki çizimleri. Bird'ün birim koordinatlarında (0…1) çalışır:
/// gövde merkezi (0.5, 0.58), başın tepesi ~y 0.23, göz (0.64, 0.44), burun 0.80–0.97, tasma ~y 0.75.
enum OutfitArt {
    private static func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h))
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    static func draw(_ o: Outfit, in ctx: inout GraphicsContext) {
        switch o {
        case .none: break
        case .beanie: beanie(&ctx)
        case .scarf: scarf(&ctx)
        case .sunglasses: sunglasses(&ctx)
        case .crown: crown(&ctx)
        case .headphones: headphones(&ctx)
        case .bowtie: bowtie(&ctx)
        case .partyHat: partyHat(&ctx)
        case .fez: fez(&ctx)
        case .santa: santa(&ctx)
        case .flower: flower(&ctx)
        }
    }

    private static func beanie(_ ctx: inout GraphicsContext) {
        let knit = rgb(0.86, 0.26, 0.28), dark = rgb(0.66, 0.16, 0.19), cuff = rgb(0.95, 0.90, 0.82)
        var dome = Path()
        dome.move(to: CGPoint(x: 0.28, y: 0.30))
        dome.addCurve(to: CGPoint(x: 0.76, y: 0.30), control1: CGPoint(x: 0.28, y: 0.07), control2: CGPoint(x: 0.76, y: 0.07))
        dome.closeSubpath()
        ctx.fill(dome, with: .color(knit))
        var ribs = ctx
        ribs.clip(to: dome)
        for x in [0.38, 0.46, 0.54, 0.62, 0.70] {
            ribs.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0.10)); p.addLine(to: CGPoint(x: x, y: 0.30)) },
                        with: .color(dark), lineWidth: 0.012)
        }
        ctx.fill(Path(roundedRect: CGRect(x: 0.25, y: 0.265, width: 0.54, height: 0.075), cornerRadius: 0.035), with: .color(cuff))
        ctx.fill(oval(0.52, 0.105, 0.11, 0.11), with: .color(cuff))
    }

    private static func scarf(_ ctx: inout GraphicsContext) {
        let red = rgb(0.85, 0.22, 0.25), cream = rgb(0.96, 0.92, 0.84)
        var band = Path()
        band.move(to: CGPoint(x: 0.30, y: 0.66))
        band.addQuadCurve(to: CGPoint(x: 0.88, y: 0.70), control: CGPoint(x: 0.58, y: 0.84))
        ctx.stroke(band, with: .color(red), style: StrokeStyle(lineWidth: 0.09, lineCap: .round))
        var tail = ctx
        tail.translateBy(x: 0.42, y: 0.75)
        tail.rotate(by: .radians(0.25))
        let r = CGRect(x: -0.045, y: 0, width: 0.09, height: 0.22)
        tail.fill(Path(roundedRect: r, cornerRadius: 0.02), with: .color(red))
        for y in [0.07, 0.13] {
            tail.fill(Path(CGRect(x: -0.045, y: y, width: 0.09, height: 0.025)), with: .color(cream))
        }
        for x in stride(from: -0.035, through: 0.036, by: 0.023) {
            tail.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0.22)); p.addLine(to: CGPoint(x: x, y: 0.26)) },
                        with: .color(red), lineWidth: 0.012)
        }
    }

    private static func sunglasses(_ ctx: inout GraphicsContext) {
        ctx.stroke(Path { p in p.move(to: CGPoint(x: 0.55, y: 0.42)); p.addLine(to: CGPoint(x: 0.36, y: 0.40)) },
                   with: .color(rgb(0.08, 0.08, 0.10)), lineWidth: 0.028)
        let lens = Path(roundedRect: CGRect(x: 0.545, y: 0.375, width: 0.21, height: 0.13), cornerRadius: 0.045)
        ctx.fill(lens, with: .color(rgb(0.07, 0.07, 0.09)))
        ctx.stroke(Path { p in p.move(to: CGPoint(x: 0.58, y: 0.40)); p.addLine(to: CGPoint(x: 0.63, y: 0.395)) },
                   with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 0.018, lineCap: .round))
    }

    private static func crown(_ ctx: inout GraphicsContext) {
        let gold = rgb(0.98, 0.79, 0.24), edge = rgb(0.78, 0.56, 0.10)
        var p = Path()
        p.move(to: CGPoint(x: 0.35, y: 0.27))
        p.addLine(to: CGPoint(x: 0.35, y: 0.15))
        p.addLine(to: CGPoint(x: 0.43, y: 0.21))
        p.addLine(to: CGPoint(x: 0.50, y: 0.10))
        p.addLine(to: CGPoint(x: 0.57, y: 0.21))
        p.addLine(to: CGPoint(x: 0.65, y: 0.15))
        p.addLine(to: CGPoint(x: 0.65, y: 0.27))
        p.closeSubpath()
        ctx.fill(p, with: .color(gold))
        ctx.stroke(p, with: .color(edge), style: StrokeStyle(lineWidth: 0.012, lineJoin: .round))
        ctx.fill(oval(0.50, 0.235, 0.05, 0.05), with: .color(rgb(0.90, 0.20, 0.30)))
        ctx.fill(oval(0.405, 0.24, 0.032, 0.032), with: .color(rgb(0.30, 0.55, 1.0)))
        ctx.fill(oval(0.595, 0.24, 0.032, 0.032), with: .color(rgb(0.30, 0.55, 1.0)))
    }

    private static func headphones(_ ctx: inout GraphicsContext) {
        var band = Path()
        band.move(to: CGPoint(x: 0.44, y: 0.38))
        band.addQuadCurve(to: CGPoint(x: 0.73, y: 0.25), control: CGPoint(x: 0.50, y: 0.03))
        ctx.stroke(band, with: .color(rgb(0.16, 0.16, 0.19)), style: StrokeStyle(lineWidth: 0.045, lineCap: .round))
        ctx.fill(oval(0.46, 0.43, 0.15, 0.19), with: .color(rgb(0.14, 0.14, 0.17)))
        ctx.fill(oval(0.46, 0.43, 0.08, 0.11), with: .color(rgb(0.40, 0.68, 1.0)))
    }

    private static func bowtie(_ ctx: inout GraphicsContext) {
        let c = rgb(0.25, 0.45, 0.95)
        var l = Path()
        l.move(to: CGPoint(x: 0.740, y: 0.755)); l.addLine(to: CGPoint(x: 0.650, y: 0.700)); l.addLine(to: CGPoint(x: 0.650, y: 0.810)); l.closeSubpath()
        var r = Path()
        r.move(to: CGPoint(x: 0.740, y: 0.755)); r.addLine(to: CGPoint(x: 0.830, y: 0.700)); r.addLine(to: CGPoint(x: 0.830, y: 0.810)); r.closeSubpath()
        ctx.fill(l, with: .color(c))
        ctx.fill(r, with: .color(c))
        ctx.fill(oval(0.74, 0.755, 0.05, 0.05), with: .color(rgb(0.15, 0.30, 0.75)))
    }

    private static func partyHat(_ ctx: inout GraphicsContext) {
        var cone = Path()
        cone.move(to: CGPoint(x: 0.39, y: 0.285))
        cone.addLine(to: CGPoint(x: 0.56, y: 0.04))
        cone.addLine(to: CGPoint(x: 0.65, y: 0.265))
        cone.closeSubpath()
        ctx.fill(cone, with: .color(rgb(0.95, 0.36, 0.64)))
        var stripes = ctx
        stripes.clip(to: cone)
        for y in [0.11, 0.18, 0.25] {
            stripes.stroke(Path { p in p.move(to: CGPoint(x: 0.3, y: y + 0.03)); p.addLine(to: CGPoint(x: 0.7, y: y - 0.02)) },
                           with: .color(rgb(1.0, 0.85, 0.30)), lineWidth: 0.025)
        }
        ctx.fill(oval(0.56, 0.045, 0.075, 0.075), with: .color(rgb(1.0, 0.85, 0.30)))
    }

    private static func fez(_ ctx: inout GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: 0.40, y: 0.285))
        p.addLine(to: CGPoint(x: 0.62, y: 0.285))
        p.addLine(to: CGPoint(x: 0.585, y: 0.10))
        p.addLine(to: CGPoint(x: 0.435, y: 0.10))
        p.closeSubpath()
        ctx.fill(p, with: .color(rgb(0.78, 0.13, 0.15)))
        ctx.fill(oval(0.51, 0.10, 0.15, 0.035), with: .color(rgb(0.62, 0.09, 0.11)))
        var tassel = Path()
        tassel.move(to: CGPoint(x: 0.51, y: 0.10))
        tassel.addQuadCurve(to: CGPoint(x: 0.39, y: 0.21), control: CGPoint(x: 0.40, y: 0.08))
        ctx.stroke(tassel, with: .color(rgb(0.10, 0.08, 0.06)), lineWidth: 0.018)
        ctx.fill(oval(0.39, 0.225, 0.035, 0.05), with: .color(rgb(0.10, 0.08, 0.06)))
    }

    private static func santa(_ ctx: inout GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: 0.30, y: 0.29))
        p.addQuadCurve(to: CGPoint(x: 0.14, y: 0.19), control: CGPoint(x: 0.30, y: 0.07))
        p.addQuadCurve(to: CGPoint(x: 0.73, y: 0.27), control: CGPoint(x: 0.60, y: 0.00))
        p.closeSubpath()
        ctx.fill(p, with: .color(rgb(0.86, 0.17, 0.20)))
        ctx.fill(Path(roundedRect: CGRect(x: 0.26, y: 0.245, width: 0.50, height: 0.085), cornerRadius: 0.04), with: .color(.white))
        ctx.fill(oval(0.13, 0.19, 0.10, 0.10), with: .color(.white))
    }

    private static func flower(_ ctx: inout GraphicsContext) {
        let c = CGPoint(x: 0.44, y: 0.22)
        for i in 0..<5 {
            let a = Double(i) / 5 * 2 * .pi - .pi / 2
            ctx.fill(oval(c.x + cos(a) * 0.045, c.y + sin(a) * 0.045, 0.065, 0.065), with: .color(rgb(1.0, 0.56, 0.72)))
        }
        ctx.fill(oval(c.x, c.y, 0.05, 0.05), with: .color(rgb(1.0, 0.84, 0.30)))
    }

    // MARK: - Tepki çizimleri

    /// Sinirli: kabarmış tepe tüyleri (kulak renginde), çatık kaş, öfke işareti.
    static func annoyedSpikes(_ ctx: inout GraphicsContext, feather: Color, k: Double) {
        for (i, x) in [0.43, 0.51, 0.59].enumerated() {
            var spike = Path()
            spike.move(to: CGPoint(x: x - 0.035, y: 0.27))
            spike.addLine(to: CGPoint(x: x + Double(i - 1) * 0.02, y: 0.27 - 0.11 * k))
            spike.addLine(to: CGPoint(x: x + 0.035, y: 0.27))
            spike.closeSubpath()
            ctx.fill(spike, with: .color(feather))
        }
    }

    static func annoyedFace(_ ctx: inout GraphicsContext, k: Double) {
        ctx.stroke(Path { p in p.move(to: CGPoint(x: 0.56, y: 0.335)); p.addLine(to: CGPoint(x: 0.72, y: 0.385)) },
                   with: .color(.black), style: StrokeStyle(lineWidth: 0.04, lineCap: .round))
        let red = Color(red: 0.95, green: 0.25, blue: 0.25).opacity(k)
        let m = CGPoint(x: 0.86, y: 0.18), r = 0.05 * k
        for a in stride(from: 0.0, to: 2 * .pi, by: .pi / 2) {
            var arc = Path()
            arc.addArc(center: CGPoint(x: m.x + cos(a + .pi / 4) * r * 1.4, y: m.y + sin(a + .pi / 4) * r * 1.4),
                       radius: r, startAngle: .radians(a + .pi * 0.75), endAngle: .radians(a + .pi * 1.25), clockwise: false)
            ctx.stroke(arc, with: .color(red), style: StrokeStyle(lineWidth: 0.025, lineCap: .round))
        }
    }

    /// Başı dönmüş: dönen spiral göz ve başın üstünde dolanan yıldızlar.
    static func dizzy(_ ctx: inout GraphicsContext, eye: CGPoint, t: Double) {
        ctx.fill(oval(eye.x, eye.y, 0.16, 0.16), with: .color(.white))
        var spiral = Path()
        let turns = 2.6, steps = 60
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let a = f * turns * 2 * .pi + t * 7
            let r = 0.008 + f * 0.062
            let pt = CGPoint(x: eye.x + cos(a) * r, y: eye.y + sin(a) * r)
            if i == 0 { spiral.move(to: pt) } else { spiral.addLine(to: pt) }
        }
        ctx.stroke(spiral, with: .color(.black), style: StrokeStyle(lineWidth: 0.018, lineCap: .round))
        for i in 0..<3 {
            let a = t * 4.5 + Double(i) * 2.09
            let c = CGPoint(x: 0.52 + cos(a) * 0.24, y: 0.13 + sin(a) * 0.06)
            ctx.fill(star(c, 0.045), with: .color(Color(red: 1.0, green: 0.84, blue: 0.30)))
        }
    }

    private static func star(_ c: CGPoint, _ r: Double) -> Path {
        var p = Path()
        for i in 0..<8 {
            let a = Double(i) / 8 * 2 * .pi - .pi / 2
            let rr = i % 2 == 0 ? r : r * 0.4
            let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}
