import SwiftUI

/// Tüm özelliklerin tek kayıt noktası. Her özellik grubu buraya kendi satırını ekler;
/// böylece paralel geliştirilen dallar yalnızca bu dosyada, satır satır birleşir.
@MainActor enum Features {
    static func register(_ app: AppState) {
        // pill'ler
        Integrations.register(app)
        // ajanlar
        // karakter
        // sohbet
        // ses
    }
}
