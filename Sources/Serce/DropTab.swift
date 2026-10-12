import SwiftUI
import UniformTypeIdentifiers

/// Dosya bırakma sekmesi. Bırakılan dosyalar AppState.attachments'a girer;
/// kuş kutuya dönüşüp dosyayı yutar, sonra "Sor" ya da "E-postayla gönder".
struct DropTabView: View {
    @ObservedObject var app: AppState
    @State private var targeted = false
    /// 0 → dosya kutunun üstünde, 1 → içeri düştü.
    @State private var swallow: CGFloat = 1
    @State private var swallowing = false
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone
            if !app.attachments.isEmpty { actions }
        }
        .modifier(FileDrop(enabled: !snapshot, targeted: $targeted, perform: drop))
    }

    private var dropZone: some View {
        HStack(spacing: 22) {
            ZStack(alignment: .top) {
                BirdBox(open: targeted || swallowing, size: 64)
                if swallowing {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .scaleEffect(1 - 0.7 * swallow)
                        .offset(y: -34 + 40 * swallow)
                        .opacity(Double(1 - swallow))
                }
            }
            .frame(width: 80, height: 86)
            VStack(alignment: .leading, spacing: 8) {
                Text(targeted ? "Bırak, yutayım" : "Dosyalarını buraya bırak")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(targeted ? Palette.green : .white.opacity(0.85))
                HStack(spacing: 5) {
                    ForEach(["PDF", "Görsel", "Kod", "Belge"], id: \.self) { k in
                        Text(k).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.07)))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Palette.green.opacity(targeted ? 0.12 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Palette.green.opacity(targeted ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .animation(.easeOut(duration: 0.2), value: targeted)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            AttachmentChips(app: app)
            Button("Temizle") { app.attachments = [] }
                .buttonStyle(Pill(kind: .ghost))
            Button {
                let urls = app.attachments.compactMap { a -> URL? in if case .file(let u) = a.kind { return u } else { return nil } }
                let subject = app.attachments.map(\.name).joined(separator: ", ")
                MailComposer.compose(to: [], subject: subject, body: "", attachments: urls)
            } label: {
                Label("E-postayla gönder", systemImage: "envelope").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(Pill(kind: .quiet))
            Button {
                app.tab = .chat
            } label: {
                Label("Sor", systemImage: "bubble.left.fill").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(Pill(kind: .primary))
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in DropTabView.add(url, to: app) }
            }
        }
        if accepted { animateSwallow() }
        return accepted
    }

    @MainActor static func add(_ url: URL, to app: AppState) {
        let already = app.attachments.contains { if case .file(let u) = $0.kind { return u == url } else { return false } }
        guard !already else { return }
        app.attachments.append(Attachment(name: url.lastPathComponent, kind: .file(url)))
    }

    private func animateSwallow() {
        swallow = 0
        swallowing = true
        withAnimation(.easeIn(duration: 0.55)) { swallow = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { swallowing = false }
    }
}

/// Kutuya dönüşmüş Pepe: beyaz kutu, kapağı kulak renginde, önünde gözü, burnu ve tasması.
struct BirdBox: View {
    var open: Bool
    var size: CGFloat

    private let fur = Color(red: 0.99, green: 0.975, blue: 0.94)
    private let cap = Color(red: 0.94, green: 0.88, blue: 0.79)
    private let collar = Color(red: 0.32, green: 0.21, blue: 0.15)
    private let nose = Color(red: 0.12, green: 0.10, blue: 0.10)

    var body: some View {
        let s = size
        ZStack(alignment: .top) {
            // Gövde
            RoundedRectangle(cornerRadius: s * 0.12, style: .continuous)
                .fill(fur)
                .frame(width: s, height: s * 0.72)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(collar).frame(height: s * 0.07).offset(y: -s * 0.16)
                }
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        Ellipse().fill(nose).frame(width: s * 0.12, height: s * 0.135)
                        Circle().fill(.white).frame(width: s * 0.045).offset(x: s * 0.022, y: -s * 0.03)
                    }
                    .offset(x: -s * 0.2, y: s * 0.14)
                }
                .overlay(alignment: .trailing) {
                    Capsule().fill(nose).frame(width: s * 0.13, height: s * 0.09).offset(x: s * 0.05, y: -s * 0.02)
                }
                .offset(y: s * 0.22)
            // Kapak: açılınca geriye devrilir
            RoundedRectangle(cornerRadius: s * 0.06, style: .continuous)
                .fill(cap)
                .frame(width: s * 1.06, height: s * 0.14)
                .rotationEffect(.degrees(open ? -38 : 0), anchor: .leading)
                .offset(y: s * 0.16)
        }
        .frame(width: s * 1.1, height: s * 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: open)
    }
}

/// onDrop AppKit görünümü ister; ImageRenderer onu çizemediği için anlık görüntüde atlanır.
private struct FileDrop: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let perform: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if enabled { content.onDrop(of: [.fileURL], isTargeted: $targeted, perform: perform) } else { content }
    }
}
