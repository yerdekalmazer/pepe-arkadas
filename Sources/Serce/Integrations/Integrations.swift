import SwiftUI

/// Entegrasyon pill'lerinin kaydı. Features.register buradan çağırır.
@MainActor enum Integrations {
    static func makeAll() -> [PillProvider] {
        [StripePill(), GitHubPill(), VercelPill(), N8nPill(), ResendPill(), NotionPill(), CalcomPill()]
    }

    static func register(_ app: AppState) {
        for p in makeAll() { app.pills.register(p) }
    }
}

/// Sesli asistanın okuyacağı düz Türkçe özet. (Main'de PillProvider'a eklenecek; burada yalnızca snapshot çıktısı için.)
@MainActor protocol VoiceSummarizing { var voiceSummary: String { get } }
extension StripePill: VoiceSummarizing {}
extension GitHubPill: VoiceSummarizing {}
extension VercelPill: VoiceSummarizing {}
extension N8nPill: VoiceSummarizing {}
extension ResendPill: VoiceSummarizing {}
extension NotionPill: VoiceSummarizing {}
extension CalcomPill: VoiceSummarizing {}
