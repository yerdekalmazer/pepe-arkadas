import SwiftUI

/// Notch'taki her "pill": entegrasyonlar (Stripe, GitHub…), müzik, plan kullanımı.
/// Her sağlayıcı kendi verisini çeker ve kendi kartını çizer; kayıt Features.swift'te yapılır.
@MainActor protocol PillProvider: AnyObject {
    /// Kalıcı kimlik ("stripe", "spotify"…). Ayarlarda ve UserDefaults'ta bu anahtar kullanılır.
    var id: String { get }
    var title: String { get }
    /// Kartın üst satırındaki ikinci kelime ("Payments", "Çalıyor"…).
    var subtitle: String { get }
    /// Pill'in rengi; o pill'in kuşu bu renge boyanır.
    var color: Color { get }
    /// Gerekli anahtar/uygulama mevcut mu? false ise ayarlarda "kurulum gerekli" görünür.
    var isConfigured: Bool { get }
    /// Dikkat isteyen bir şey var mı (başarısız CI, yeni ödeme…)? Kapalı notch'ta gösterilir.
    var needsAttention: Bool { get }
    /// Ana sayfanın sol kartında görünen içerik.
    func card() -> AnyView
    /// Ayarlar penceresindeki yapılandırma alanı (API anahtarı vb.). nil ise yok.
    func settings() -> AnyView?
    /// Pill etkinleştirildiğinde/kapatıldığında çağrılır (zamanlayıcıları başlat/durdur).
    func start()
    func stop()
    /// Sesli asistanın okuyacağı 1-4 cümlelik düz özet ("Bugün 3 ödeme, toplam…").
    var voiceSummary: String { get }
}

extension PillProvider {
    var needsAttention: Bool { false }
    var voiceSummary: String { "" }
    func settings() -> AnyView? { nil }
}

@MainActor final class PillRegistry: ObservableObject {
    static let maxActive = 5
    /// Snapshot modunda false: kullanıcının pill seçimini değiştirmesin.
    var persists = true
    @Published private(set) var all: [PillProvider] = []
    @Published private(set) var activeIds: [String] = UserDefaults.standard.stringArray(forKey: "aktifPilller") ?? []

    var active: [PillProvider] { activeIds.compactMap { id in all.first { $0.id == id } } }

    func register(_ p: PillProvider) {
        guard !all.contains(where: { $0.id == p.id }) else { return }
        all.append(p)
        if activeIds.contains(p.id) { p.start() }
    }

    func provider(_ id: String) -> PillProvider? { all.first { $0.id == id } }

    func isActive(_ id: String) -> Bool { activeIds.contains(id) }

    /// En fazla 5 pill açık olabilir; doluysa en eskisi kapanır.
    func setActive(_ id: String, _ on: Bool) {
        var ids = activeIds
        if on, !ids.contains(id) {
            ids.append(id)
            if ids.count > Self.maxActive { provider(ids.removeFirst())?.stop() }
            provider(id)?.start()
        } else if !on, ids.contains(id) {
            ids.removeAll { $0 == id }
            provider(id)?.stop()
        }
        activeIds = ids
        if persists { UserDefaults.standard.set(ids, forKey: "aktifPilller") }
    }

    /// Sesli asistan ve kısayollar için: bir pill'i diğeriyle değiştir.
    func swap(_ old: String, with new: String) {
        guard let i = activeIds.firstIndex(of: old) else { setActive(new, true); return }
        provider(old)?.stop()
        var ids = activeIds
        ids[i] = new
        activeIds = ids
        if persists { UserDefaults.standard.set(ids, forKey: "aktifPilller") }
        provider(new)?.start()
    }
}

/// Sağdaki pill ızgarası: renkli küçük kuş + ad. Seçilen pill soldaki kartta açılır.
struct PillGrid: View {
    @ObservedObject var app: AppState
    @ObservedObject var registry: PillRegistry

    var body: some View {
        let items: [(id: String?, title: String, color: Color, attention: Bool)] =
            [(nil, "Claude Code", Color.white, !app.store.approvals.isEmpty)] +
            registry.active.map { ($0.id, $0.title, $0.color, $0.needsAttention) }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(items, id: \.title) { item in
                PillChip(title: item.title, color: item.color, selected: app.selectedPill == item.id,
                         attention: item.attention) {
                    app.selectedPill = item.id
                }
            }
        }
    }
}

struct PillChip: View {
    let title: String
    let color: Color
    let selected: Bool
    let attention: Bool
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 7) {
                Bird(mood: attention ? .alert : .idle, size: 18, tint: color == .white ? nil : color)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if attention { Circle().fill(Palette.amber).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(selected ? color.opacity(0.22) : .white.opacity(hover ? 0.08 : 0.04)))
            .overlay(Capsule().stroke(selected ? color.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
