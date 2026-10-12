import AppKit
import SwiftUI

struct MemorySettings: View {
    @ObservedObject var meter: UsageMeter
    @ObservedObject var memory: ProjectMemory
    @AppStorage("hafizaAcik") private var on = true
    @AppStorage("hafizaBaglam") private var inject = true
    @AppStorage("hafizaOzet") private var summarize = true
    @AppStorage("hafizaModeli") private var model = "claude-haiku-5-5"
    @AppStorage("arkaPlanModel") private var agentModel = ""
    @AppStorage("paralelOturum") private var parallel = 4

    var body: some View {
        SettingsGroup(title: "Proje hafızası",
                      footer: "Her proje için bir md: Application Support/Serce/Hafiza (Obsidian'da \"(05) Projeler/Serçe Hafızası\"). Oturum günlüğü LLM'siz yazılır; özet yalnızca dosya değiştiren ya da birkaç komut çalıştıran bir oturum bitince, kısa bir girdiyle güncellenir. Md'leri elle de düzenleyebilirsin.") {
            Toggle("Oturumları proje md'lerine yaz", isOn: $on)
            Toggle("Yeni Claude Code oturumlarına projenin kısa özetini ver (~400 token)", isOn: $inject).disabled(!on)
            Toggle("Oturum bitince Durum / Sıradaki / Kararlar'ı özetle", isOn: $summarize).disabled(!on)
            Picker("Özet modeli", selection: $model) {
                Text("Claude Haiku 5.5 — en ucuz (önerilen)").tag("claude-haiku-5-5")
                Text("Claude Sonnet 5.5").tag("claude-sonnet-5-5")
                Text("Claude Opus 5.5").tag("claude-opus-5-5")
            }
            .disabled(!on || !summarize)
            HStack {
                Button("Klasörü aç") {
                    try? FileManager.default.createDirectory(at: ProjectMemory.dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ProjectMemory.dir)
                }
                Text("\(ProjectMemory.allDocs().count) proje").foregroundStyle(.secondary)
            }
        }
        SettingsGroup(title: "Bütçe",
                      footer: "Arka plan özetleri günlük bütçeye ulaşınca o gün durur; sohbet ve ses etkilenmez. Maliyetler liste fiyatından tahmindir.") {
            Picker("Serçe'nin başlattığı oturumlar", selection: $agentModel) {
                Text("Claude Code varsayılanı").tag("")
                Text("Opus").tag("opus")
                Text("Sonnet — daha ucuz").tag("sonnet")
                Text("Haiku — en ucuz").tag("haiku")
            }
            Stepper("Aynı anda en fazla \(parallel) oturum", value: $parallel, in: 1...8)
            HStack {
                Text("Günlük arka plan bütçesi")
                Spacer()
                TextField("", value: Binding(get: { meter.backgroundBudget }, set: { meter.backgroundBudget = max(0, $0) }),
                          format: .currency(code: "USD"))
                    .frame(width: 90).textFieldStyle(.roundedBorder)
            }
            Divider()
            let today = meter.today
            ForEach(UsageMeter.Purpose.allCases, id: \.self) { p in
                let t = today[p.rawValue] ?? UsageMeter.Totals()
                HStack {
                    Text(p.rawValue).frame(width: 120, alignment: .leading)
                    Text("\(t.calls) çağrı").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    Text("\(Self.k(t.input + t.cacheRead + t.cacheWrite)) giriş · \(Self.k(t.output)) çıkış")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "$%.3f", t.cost)).monospacedDigit()
                }
                .font(.callout)
            }
            let all = meter.todayTotal()
            HStack {
                Text("Bugün toplam").fontWeight(.semibold)
                if all.input + all.cacheRead > 0 {
                    Text("önbellekten: %\(Int(Double(all.cacheRead) / Double(all.input + all.cacheRead + all.cacheWrite) * 100))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "$%.3f", all.cost)).monospacedDigit().fontWeight(.semibold)
            }
        }
    }

    static func k(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
}

enum MemoryFeature {
    @MainActor static func register(_ app: AppState) {
        ProjectMemory.shared.start()
        SettingsRegistry.shared.add(SettingsSection(id: "hafiza", title: "Hafıza ve bütçe", icon: "brain", order: 30) {
            AnyView(MemorySettings(meter: .shared, memory: .shared))
        })
    }
}
