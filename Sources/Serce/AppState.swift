import AppKit
import SwiftUI

enum IslandTab: String, CaseIterable { case home, chat, drop }

/// Uygulamanın her yerinden (kısayollar, sesli asistan, menü) çağrılabilen eylemler.
/// NotchController ve AppDelegate açılışta doldurur.
struct AppActions {
    var expand: () -> Void = {}
    var collapse: () -> Void = {}
    var openTab: (IslandTab) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var openTerminal: (AgentSession) -> Void = { _ in }
    var jumpToAlert: () -> Void = {}
    /// Ada şu an açık mı (kısayolla aç/kapat için).
    var isExpanded: () -> Bool = { false }
}

/// Paylaşılan durum merkezi: oturumlar, pill'ler, açık sekme. Özellikler buraya kaydolur.
@MainActor final class AppState: ObservableObject {
    static let shared = AppState()

    let store = SessionStore()
    let pills = PillRegistry()
    @Published var tab: IslandTab = .home
    /// Ana sayfanın sol kartında gösterilen pill; nil ise ajan oturumları.
    @Published var selectedPill: String?
    var actions = AppActions()
    /// Müzik pill'leri çalarken true; kuş dans eder.
    @Published var musicPlaying = false
    /// Sohbete eklenecek dosya/görsel/metinler. Dosya bırakma ve pencere sürükleme buraya yazar, sohbet okur.
    @Published var attachments: [Attachment] = []

    /// Karakterin genel ruh hali: bekleyen izin > pill uyarısı > oturumlar.
    var mood: Mood {
        let m = store.mood
        return (m == .idle || m == .sleep) && musicPlaying ? .dance : m
    }
}

struct Attachment: Identifiable, Equatable {
    enum Kind: Equatable {
        case file(URL)
        case image(Data)
        case text(String)
    }
    let id = UUID()
    var name: String
    var kind: Kind
}
