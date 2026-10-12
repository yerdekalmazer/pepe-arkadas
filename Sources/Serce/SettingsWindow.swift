import AppKit
import ServiceManagement
import SwiftUI

/// Ayarlar penceresindeki bir bölüm. Özellik grupları Features.register içinde kendi bölümlerini ekler.
struct SettingsSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// Kenar çubuğundaki sıra; küçük olan üstte.
    var order: Int = 50
    let view: @MainActor () -> AnyView
}

@MainActor final class SettingsRegistry: ObservableObject {
    static let shared = SettingsRegistry()
    @Published private(set) var sections: [SettingsSection] = []

    func add(_ s: SettingsSection) {
        sections.removeAll { $0.id == s.id }
        sections.append(s)
        sections.sort { $0.order < $1.order }
    }
}

@MainActor final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(section: String? = nil) {
        if let section { UserDefaults.standard.set(section, forKey: "ayarBolumu") }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Serçe Ayarları"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(registry: .shared))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var registry: SettingsRegistry
    @AppStorage("ayarBolumu") private var selected = "genel"

    var body: some View {
        NavigationSplitView {
            List(registry.sections, selection: Binding(get: { selected }, set: { selected = $0 ?? "genel" })) { s in
                Label(s.title, systemImage: s.icon).tag(s.id)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            if let s = registry.sections.first(where: { $0.id == selected }) ?? registry.sections.first {
                ScrollView {
                    s.view()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
                .navigationTitle(s.title)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

// MARK: - Ortak ayar parçaları

/// Başlıklı ayar grubu.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.bottom, 18)
    }
}

/// Keychain'e yazan API anahtarı alanı. Değer ekranda maskelenir.
struct SecretField: View {
    let title: String
    let key: String
    var placeholder = "Anahtarı yapıştır"
    var onChange: () -> Void = {}
    @State private var value = ""
    @State private var loaded = false

    var body: some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            SecureField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Button("Kaydet", action: save).disabled(!loaded)
            if Keychain.get(key) != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Kayıtlı")
            }
        }
        .onAppear {
            value = Keychain.get(key) ?? ""
            loaded = true
        }
    }

    private func save() {
        Keychain.set(key, value.trimmingCharacters(in: .whitespacesAndNewlines))
        onChange()
    }
}

// MARK: - Temel bölümler

enum CoreSettings {
    @MainActor static func register(_ app: AppState) {
        let r = SettingsRegistry.shared
        r.add(SettingsSection(id: "genel", title: "Genel", icon: "gearshape", order: 0) { AnyView(GeneralSettings(store: app.store)) })
        r.add(SettingsSection(id: "ajanlar", title: "Ajanlar", icon: "terminal", order: 10) { AnyView(AgentSettings()) })
        r.add(SettingsSection(id: "pilller", title: "Aktif pill'ler", icon: "capsule", order: 20) { AnyView(PillSettings(registry: app.pills)) })
    }
}

struct GeneralSettings: View {
    @ObservedObject var store: SessionStore
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        SettingsGroup(title: "Davranış") {
            Toggle("Sesler", isOn: Binding(get: { store.soundsOn }, set: { store.soundsOn = $0 }))
            Toggle("Girişte başlat", isOn: Binding(get: { login }, set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {}
                login = SMAppService.mainApp.status == .enabled
            }))
        }
        SettingsGroup(title: "Hakkında", footer: "Serçe, Claude Code oturumlarını notch'ta izler. Her şey bu Mac'te kalır; yalnızca kendi anahtarınla açtığın servislere istek gider.") {
            Text("Serçe 0.2").font(.system(.body, design: .rounded).weight(.semibold))
        }
    }
}

struct AgentSettings: View {
    @State private var installed = HookInstaller.isInstalled()
    @State private var error: String?

    var body: some View {
        SettingsGroup(title: "Claude Code", footer: "Hook'lar ~/.claude/settings.json içine eklenir; önceki hali settings.json.serce-yedek olarak saklanır.") {
            HStack {
                Image(systemName: installed ? "checkmark.circle.fill" : "circle").foregroundStyle(installed ? .green : .secondary)
                Text(installed ? "Bağlı" : "Bağlı değil")
                Spacer()
                Button(installed ? "Bağlantıyı kaldır" : "Bağla") {
                    do {
                        if installed { try HookInstaller.uninstall() } else { try HookInstaller.install() }
                        error = nil
                    } catch let e { error = e.localizedDescription }
                    installed = HookInstaller.isInstalled()
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        ForEach(AgentRegistry.shared.agents) { a in
            SettingsGroup(title: a.name, footer: a.footer) { a.view() }
        }
    }
}

/// Claude Code dışındaki ajanlar (Codex, Gemini CLI, Cursor…) kendi kurulum satırlarını buraya ekler.
struct AgentEntry: Identifiable {
    let id: String
    let name: String
    var footer: String? = nil
    let view: @MainActor () -> AnyView
}

@MainActor final class AgentRegistry {
    static let shared = AgentRegistry()
    private(set) var agents: [AgentEntry] = []
    func add(_ a: AgentEntry) { agents.removeAll { $0.id == a.id }; agents.append(a) }
}

struct PillSettings: View {
    @ObservedObject var registry: PillRegistry

    var body: some View {
        SettingsGroup(title: "Notch'ta görünenler", footer: "En fazla \(PillRegistry.maxActive) pill açık olabilir. Anahtar isteyen pill'ler için alanlar aşağıda.") {
            if registry.all.isEmpty {
                Text("Henüz pill yok.").foregroundStyle(.secondary)
            }
            ForEach(registry.all, id: \.id) { p in
                HStack(spacing: 10) {
                    Bird(mood: .idle, size: 22, tint: p.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title)
                        Text(p.isConfigured ? p.subtitle : "Kurulum gerekli").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { registry.isActive(p.id) }, set: { registry.setActive(p.id, $0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
        ForEach(registry.all, id: \.id) { p in
            if let v = p.settings() {
                SettingsGroup(title: p.title) { v }
            }
        }
    }
}
