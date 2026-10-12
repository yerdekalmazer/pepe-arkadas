import SwiftUI

/// Dosya bırakma sekmesi. (Sohbet özellik grubu bu dosyayı tamamen değiştirir.)
struct DropTabView: View {
    @ObservedObject var app: AppState
    var body: some View {
        Text("Dosyanı buraya bırak").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 120)
    }
}
