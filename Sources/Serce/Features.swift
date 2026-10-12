import SwiftUI

/// Tüm özelliklerin tek kayıt noktası. Her özellik grubu buraya kendi satırını ekler;
/// böylece paralel geliştirilen dallar yalnızca bu dosyada, satır satır birleşir.
@MainActor enum Features {
    static func register(_ app: AppState) {
        // pill'ler
        // pill'ler: müzik (Spotify, Apple Music)
        app.pills.register(MusicController(.spotify))
        app.pills.register(MusicController(.music))
        // ajanlar
        // karakter
        // sohbet
        // ses
        VoiceFeature.register(app)
    }
}
