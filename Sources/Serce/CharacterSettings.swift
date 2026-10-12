import AppKit
import SwiftUI

/// Ayarlar → Karakter: gardırop, masaüstü kuşu, sesler.
struct CharacterSettings: View {
    @ObservedObject var character: CharacterState

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        SettingsGroup(title: "Gardırop", footer: "Pepe'ye sağ tıklayarak da giydirebilirsin. \"Mevsime göre\" seçiliyken kışın atkı, yılbaşında şapka, baharda çiçek, yazın gözlük takar.") {
            LazyVGrid(columns: columns, spacing: 10) {
                OutfitTile(title: "Mevsime göre", outfit: Outfit.seasonal(), selected: character.chosen == nil) {
                    character.choose(nil)
                }
                ForEach(Outfit.allCases) { o in
                    OutfitTile(title: o.title, outfit: o, selected: character.chosen == o) { character.choose(o) }
                }
            }
        }
        SettingsGroup(title: "Masaüstünde Pepe", footer: "Pepe'yi adadan aşağı sürükleyerek de bırakabilirsin. Bir pencerenin üstüne bırakırsan o pencerenin görüntüsü sohbete eklenir; çift tıklayınca eve döner.") {
            HStack {
                Button("Masaüstüne gönder") { DesktopBirdController.shared.sendToDesktop() }
                Button("Eve çağır") { DesktopBirdController.shared.goHome() }
            }
        }
        SettingsGroup(title: "Sesler", footer: "Bir sesi değiştirmek için klasöre aynı adla (ör. done.wav) bir dosya koy. .wav, .mp3, .aiff ve .m4a olur.") {
            ForEach(SoundEngine.Cue.allCases, id: \.self) { cue in
                HStack {
                    Text(cue.title)
                    Text(cue.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        SoundEngine.shared.play(cue, force: true)
                    } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                }
            }
            Button("Ses klasörünü aç") {
                SoundEngine.shared.prepareFolder()
                NSWorkspace.shared.open(SoundEngine.folder)
            }
        }
    }
}

private struct OutfitTile: View {
    let title: String
    let outfit: Outfit
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Bird(mood: .idle, size: 54, outfit: outfit, eyes: .fixed)
                Text(title).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
