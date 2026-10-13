import SwiftUI

/// Ana sayfanın sol kartı: kapak, parça, sarılabilir ilerleme çubuğu, kontroller, ses.
struct MusicCard: View {
    @ObservedObject var controller: MusicController

    var body: some View {
        if !controller.running {
            placeholder(text: "\(controller.app.name) açık değil", button: controller.app == .spotify ? "Spotify'ı aç" : "Apple Music'i aç") { controller.openApp() }
        } else if let now = controller.now {
            player(now)
        } else {
            placeholder(text: "Şu an bir şey çalmıyor", button: nil, action: nil)
        }
    }

    private func player(_ now: NowPlaying) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Artwork(image: controller.artwork, color: controller.color, playing: now.playing)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Circle().fill(controller.color).frame(width: 6, height: 6)
                        Text(controller.app.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text(now.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text(now.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressScrubber(now: now, color: controller.color) { controller.send(.seek($0)) }
                HStack(spacing: 14) {
                    ControlIcon(symbol: "shuffle", active: now.shuffle) { controller.send(.shuffle(!now.shuffle)) }
                    ControlIcon(symbol: "backward.fill") { controller.send(.previous) }
                    Button { controller.send(.playPause) } label: {
                        Image(systemName: now.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.white))
                    }
                    .buttonStyle(.plain)
                    ControlIcon(symbol: "forward.fill") { controller.send(.next) }
                    ControlIcon(symbol: now.repeatMode == .one ? "repeat.1" : "repeat", active: now.repeatMode != .off) {
                        controller.send(.repeatMode(nextRepeat(now.repeatMode)))
                    }
                    Spacer(minLength: 4)
                    VolumeSlider(volume: now.volume) { controller.send(.volume($0)) }
                }
            }
        }
    }

    /// Spotify yalnızca açık/kapalı tekrar bilir; Apple Music kapalı → tümü → tek şarkı döner.
    private func nextRepeat(_ r: NowPlaying.Repeat) -> NowPlaying.Repeat {
        if controller.app == .spotify { return r == .off ? .all : .off }
        switch r {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    private func placeholder(text: String, button: String?, action: (() -> Void)?) -> some View {
        HStack(spacing: 14) {
            Bird(mood: .sleep, size: 44, tint: controller.color)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 13, weight: .semibold))
                if let button, let action {
                    Button(button, action: action).buttonStyle(Pill(kind: .quiet))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct Artwork: View {
    let image: NSImage?
    let color: Color
    let playing: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(color.opacity(0.18))
                Image(systemName: "music.note").font(.system(size: 26, weight: .semibold)).foregroundStyle(color)
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if playing { Equalizer(color: .white, bars: 3, height: 12).padding(6) }
        }
    }
}

/// Sürüklenerek sarılan ilerleme çubuğu; bırakınca çalar oraya atlar.
struct ProgressScrubber: View {
    let now: NowPlaying
    let color: Color
    let seek: (Double) -> Void
    @State private var dragValue: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { tl in
            let pos = dragValue ?? now.position(at: tl.date)
            let fraction = now.duration > 0 ? max(0, min(1, pos / now.duration)) : 0
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(dragValue == nil ? .white : color).frame(width: geo.size.width * fraction)
                        Circle().fill(.white).frame(width: 9, height: 9)
                            .offset(x: geo.size.width * fraction - 4.5)
                            .opacity(dragValue == nil ? 0 : 1)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragValue = max(0, min(1, g.location.x / max(1, geo.size.width))) * now.duration
                        }
                        .onEnded { _ in
                            if let v = dragValue { seek(v) }
                            dragValue = nil
                        })
                }
                .frame(height: 12)
                HStack {
                    Text(Self.time(pos))
                    Spacer()
                    Text("-" + Self.time(max(0, now.duration - pos)))
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
        }
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct VolumeSlider: View {
    let volume: Double
    let set: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        let v = drag ?? volume
        HStack(spacing: 5) {
            Image(systemName: v < 1 ? "speaker.slash.fill" : (v < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 14)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(.white.opacity(0.8)).frame(width: geo.size.width * CGFloat(v / 100))
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in drag = max(0, min(100, Double(g.location.x / max(1, geo.size.width)) * 100)) }
                    .onEnded { _ in
                        if let d = drag { set(d) }
                        drag = nil
                    })
            }
            .frame(width: 60, height: 12)
        }
    }
}

struct ControlIcon: View {
    let symbol: String
    var active = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Palette.green : .white.opacity(hover ? 1 : 0.7))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Zıplayan çubuklar: çalarken kapağın köşesinde ve kapalı notch'un sağ kanadında.
struct Equalizer: View {
    var color: Color = Palette.green
    var bars = 4
    var height: CGFloat = 12

    var body: some View {
        // Müzik çaldıkça saatlerce görünür: düşük kare hızı yeterli.
        TimelineView(.animation(minimumInterval: 1.0 / 8)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = Double(i) * 1.7
                    let v = 0.3 + 0.7 * abs(sin(t * (3.1 + Double(i) * 0.6) + phase))
                    Capsule().fill(color).frame(width: 2.5, height: max(2, height * v))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
    }
}
