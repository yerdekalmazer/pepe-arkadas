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

