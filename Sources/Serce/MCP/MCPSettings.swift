import AppKit
import SwiftUI

struct MCPSettings: View {
    @ObservedObject var hub: MCPHub
    @State private var expanded: Set<String> = []
    @State private var adding = false

    var body: some View {
        SettingsGroup(title: "Durum",
                      footer: "Bağlı MCP araçlarını sohbet (Claude seçiliyken) ve « OK Pepe » kullanır. Salt okuma araçları doğrudan çalışır; yazma yapanlar notch'ta onay ister. Claude Code, Claude Desktop, Cursor ve Codex'te tanımlı sunucular kendiliğinden içe alınır; anahtarları kendi dosyalarında kalır.") {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("\(hub.readyCount) sunucu bağlı · \(hub.toolCount) araç")
                Spacer()
                Button("Yenile") { hub.reload() }
                Button("Sunucu ekle…") { adding = true }
            }
        }
        ForEach(MCPServerConfig.Source.allCases, id: \.self) { source in
            let list = hub.servers.filter { $0.source == source }
            if !list.isEmpty {
                SettingsGroup(title: source.rawValue) {
                    ForEach(list) { c in row(c) }
                }
            }
        }
        .sheet(isPresented: $adding) { AddServerSheet(hub: hub, done: { adding = false }) }
    }

    @ViewBuilder private func row(_ c: MCPServerConfig) -> some View {
        let st = hub.status[c.id] ?? .off
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(color(st)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).fontWeight(.medium)
                    Text(c.summary.isEmpty ? c.transportLabel : "\(c.summary) · \(c.transportLabel)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                statusView(c, st)
                Toggle("", isOn: Binding(get: { hub.isEnabled(c) }, set: { hub.setEnabled(c, $0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            if case .failed(let m) = st {
                Text(m).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if expanded.contains(c.id), let tools = hub.tools[c.id] {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(tools) { t in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: t.readOnly ? "eye" : "pencil").font(.caption2).foregroundStyle(.secondary).frame(width: 12)
                            Text(t.name).font(.system(.caption, design: .monospaced))
                            Text(t.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if c.source == .custom {
                Button("Kaldır") { MCPConfigLoader.removeCustom(name: c.name); hub.reload() }
            }
            if case .oauth = c.auth, MCPOAuth.stored(c.id) != nil {
                Button("Çıkış yap") { hub.signOut(c) }
            }
        }
    }

    @ViewBuilder private func statusView(_ c: MCPServerConfig, _ st: MCPHub.Status) -> some View {
        switch st {
        case .connecting:
            ProgressView().controlSize(.small)
        case .ready(let n):
            Button("\(n) araç") {
                if expanded.contains(c.id) { expanded.remove(c.id) } else { expanded.insert(c.id) }
            }
            .buttonStyle(.link)
        case .needsAuth:
            if hub.signingIn == c.id {
                Text("Tarayıcıda giriş bekleniyor…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Bağlan") { Task { await hub.signIn(c) } }
            }
        case .failed:
            Button("Tekrar dene") { Task { await hub.connect(c) } }
        case .off:
            if case .oauth = c.auth, MCPOAuth.stored(c.id) == nil {
                Button("Bağlan") { Task { await hub.signIn(c) } }
            }
        }
    }

    private func color(_ s: MCPHub.Status) -> Color {
        switch s {
        case .ready: .green
        case .connecting: .blue
        case .needsAuth: .orange
        case .failed: .red
        case .off: .gray.opacity(0.5)
        }
    }
}

private struct AddServerSheet: View {
    @ObservedObject var hub: MCPHub
    let done: () -> Void
    @State private var name = ""
    @State private var kind = 0
    @State private var url = ""
    @State private var command = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP sunucusu ekle").font(.headline)
            TextField("Ad (ör. Supabase)", text: $name)
            Picker("", selection: $kind) {
                Text("Uzak (HTTP)").tag(0)
                Text("Yerel komut (stdio)").tag(1)
            }
            .pickerStyle(.segmented)
            if kind == 0 {
                TextField("https://…/mcp", text: $url)
                SecureField("Bearer token (isteğe bağlı; yoksa gerekirse tarayıcıda giriş)", text: $token)
            } else {
                TextField("Komut, ör. npx -y @modelcontextprotocol/server-filesystem ~/Belgeler", text: $command)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Vazgeç", action: done)
                Button("Ekle") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { error = "Ad gerekli."; return }
                    let parts = command.split(separator: " ").map(String.init)
                    do {
                        try MCPConfigLoader.saveCustom(name: n, url: kind == 0 ? url : nil,
                                                       command: kind == 1 ? parts.first : nil,
                                                       args: Array(parts.dropFirst()), token: token)
                        hub.reload()
                        done()
                    } catch let e { error = e.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 480)
    }
}

enum MCPFeature {
    @MainActor static func register(_ app: AppState) {
        SettingsRegistry.shared.add(SettingsSection(id: "mcp", title: "MCP", icon: "point.3.connected.trianglepath.dotted", order: 35) {
            AnyView(MCPSettings(hub: .shared))
        })
        MCPHub.shared.reload()
    }
}
