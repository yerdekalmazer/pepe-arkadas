import SwiftUI

/// Sohbet sekmesi. (Sohbet özellik grubu bu dosyayı tamamen değiştirir.)
struct ChatTabView: View {
    @ObservedObject var app: AppState
    var body: some View {
        Text("Sohbet yakında").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 120)
    }
}
