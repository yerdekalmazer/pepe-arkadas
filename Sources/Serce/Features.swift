import SwiftUI

/// Tüm özelliklerin tek kayıt noktası. Her özellik grubu buraya kendi satırını ekler;
/// böylece paralel geliştirilen dallar yalnızca bu dosyada, satır satır birleşir.
@MainActor enum Features {
    static func register(_ app: AppState) {
        // pill'ler
        // pill'ler: müzik (Spotify, Apple Music)
        app.pills.register(MusicController(.spotify))
        app.pills.register(MusicController(.music))
        Integrations.register(app)
        // ajanlar
        AgentFeatures.register(app)
        CodexWatcherFeature.register(app)
        // karakter
        CharacterFeature.register(app)
        // sohbet
        ChatFeature.register(app)
        // kişisel
        PersonalFeature.register(app)
        // hafıza
        MemoryFeature.register(app)
        // mcp
        MCPFeature.register(app)
        // ses
        VoiceFeature.register(app)
    }
}
