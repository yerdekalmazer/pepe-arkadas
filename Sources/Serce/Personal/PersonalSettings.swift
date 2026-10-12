import AppKit
import SwiftUI

struct PersonalSettings: View {
    @ObservedObject var reminders: Reminders
    @AppStorage("brifingAcik") private var briefingOn = true
    @AppStorage("brifingSaati") private var minute = 570
    @AppStorage("brifingSesli") private var spoken = false

    var body: some View {
        SettingsGroup(title: "Ben", footer: "Sohbet ve « OK Pepe » bu dosyayı her konuşmada okur (en fazla ~1500 karakter, önbellekten). Kısa tut.") {
            HStack {
                Text("Hafiza/_ben.md")
                Spacer()
                Button("Aç") { NSWorkspace.shared.open(AboutMe.url) }
            }
        }
        SettingsGroup(title: "Sabah brifingi", footer: "LLM kullanmaz: proje md'lerinden, hatırlatmalardan ve açık pill'lerden derlenir. Pazartesileri geçen haftanın özeti de eklenir.") {
            Toggle("Her sabah göster", isOn: $briefingOn)
            DatePicker("Saat", selection: Binding(
                get: { Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date() },
                set: { d in minute = Calendar.current.component(.hour, from: d) * 60 + Calendar.current.component(.minute, from: d) }),
                       displayedComponents: .hourAndMinute)
            .disabled(!briefingOn)
            Toggle("« OK Pepe » açıksa sesli oku", isOn: $spoken).disabled(!briefingOn)
            Button("Şimdi göster") { Briefing.shared.show() }
        }
        SettingsGroup(title: "Hatırlatmalar", footer: "Sohbette ya da sesle kur: « yarın 10'da Tessera'yı hatırlat ».") {
            if reminders.upcoming.isEmpty {
                Text("Bekleyen hatırlatma yok.").foregroundStyle(.secondary)
            }
            ForEach(reminders.upcoming) { r in
                HStack {
                    Text(Reminders.format(r.at)).monospacedDigit().foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                    Text(r.text)
                    Spacer()
                    Button { _ = reminders.cancel(matching: r.text) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
        }
        SettingsGroup(title: "Trello", footer: "Anahtarlar ~/.config/trello/.env'den okunur. Pepe yalnızca Kişisel Alan ve VizeX panolarına, yalnızca sen isteyince ve onaylayınca yazar.") {
            HStack {
                Image(systemName: TrelloAPI.credentials != nil ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(TrelloAPI.credentials != nil ? .green : .secondary)
                Text(TrelloAPI.credentials != nil ? "Bağlı" : "Anahtar bulunamadı")
            }
        }
    }
}

enum PersonalFeature {
    @MainActor static func register(_ app: AppState) {
        AboutMe.seedIfNeeded()
        Reminders.shared.start()
        Briefing.shared.start()
        let trello = TrelloPill()
        app.pills.register(trello)
        // Trello anahtarı varsa pill ilk açılışta kendiliğinden açılır.
        if trello.isConfigured, !UserDefaults.standard.bool(forKey: "trelloOtoAcildi") {
            UserDefaults.standard.set(true, forKey: "trelloOtoAcildi")
            app.pills.setActive("trello", true)
        }
        SettingsRegistry.shared.add(SettingsSection(id: "kisisel", title: "Kişisel", icon: "person.crop.circle", order: 25) {
            AnyView(PersonalSettings(reminders: .shared))
        })
    }
}
