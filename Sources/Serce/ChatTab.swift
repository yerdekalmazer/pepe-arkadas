import SwiftUI

/// Sohbet sekmesi: solda kuş, mesaj balonları, altta "Devam et…" alanı.
/// Üstteki model etiketine tıklayınca sağlayıcı ve model seçilir.
struct ChatTabView: View {
    @ObservedObject var app: AppState
    @ObservedObject var chat = ChatSession.shared
    @ObservedObject var dictation = Dictation.shared
    @Environment(\.snapshotMode) private var snapshot
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            conversation.frame(height: 190)
            if !app.attachments.isEmpty { AttachmentChips(app: app) }
            inputRow
        }
    }

    // MARK: - Üst satır

    private var modelLabel: some View {
        HStack(spacing: 5) {
            Circle().fill(chat.provider.isConfigured ? Palette.green : Palette.amber).frame(width: 6, height: 6)
            Text(chat.provider.title).font(.system(size: 11, weight: .semibold))
            Text(chat.model).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if snapshot { modelLabel } else { modelMenu }
            MCPChip(hub: .shared, active: chat.provider == .anthropic)
            Spacer()
            if !chat.messages.isEmpty {
                Button(action: chat.newChat) {
                    Image(systemName: "square.and.pencil").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Yeni sohbet")
            }
        }
    }

    private var modelMenu: some View {
            Menu {
                ForEach(ChatProvider.allCases) { p in
                    Menu(p.title + (p.isConfigured ? "" : " (anahtar yok)")) {
                        ForEach(models(for: p), id: \.self) { m in
                            Button {
                                chat.select(p, model: m)
                            } label: {
                                if chat.provider == p && chat.model == m { Label(m, systemImage: "checkmark") } else { Text(m) }
                            }
                        }
                        if p.isLocal {
                            Button("Modelleri yenile") { chat.refreshLocalModels(p) }
                        }
                    }
                }
                Divider()
                Button("Sohbet ayarları…") { SettingsWindowController.shared.show(section: "sohbet") }
            } label: {
                modelLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    private func models(for p: ChatProvider) -> [String] {
        var list = p.suggestedModels + (chat.localModels[p] ?? [])
        if chat.provider == p, !chat.model.isEmpty, !list.contains(chat.model) { list.insert(chat.model, at: 0) }
        if list.isEmpty { list = ["(sunucuda model bulunamadı)"] }
        return list
    }

    // MARK: - Konuşma

    @ViewBuilder private var conversation: some View {
        if chat.messages.isEmpty {
            emptyState
        } else if snapshot {
            // ImageRenderer kaydırma alanını çizmez; son mesajlar düz basılır.
            messageList.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView { messageList }
                    .onAppear { proxy.scrollTo("son", anchor: .bottom) }
                    .onChange(of: chat.messages.last?.text) { proxy.scrollTo("son", anchor: .bottom) }
                    .onChange(of: chat.messages.count) { proxy.scrollTo("son", anchor: .bottom) }
            }
        }
    }

    private var messageList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(chat.messages) { m in
                MessageRow(message: m, streaming: chat.streaming && m.id == chat.messages.last?.id)
            }
            Color.clear.frame(height: 1).id("son")
        }
        .padding(.horizontal, 2)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            if !chat.provider.isConfigured {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(Palette.amber).font(.system(size: 11))
                    Text("\(chat.provider.title) için anahtar gerekli.").font(.system(size: 12))
                    Button("Ayarlar") { SettingsWindowController.shared.show(section: "sohbet") }
                        .buttonStyle(Pill(kind: .quiet))
                }
            } else {
                Text("Bir şey sor, dosya ekle ya da ajanlarını sor.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(["Günümü özetle", "Ajanlarım ne yapıyor?", "Son değişiklikleri açıkla"], id: \.self) { q in
                    Button(q) { chat.send(q) }
                        .buttonStyle(Pill(kind: .quiet))
                        .disabled(!chat.provider.isConfigured)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    // MARK: - Giriş

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Bird(mood: chat.streaming ? .working : (chat.messages.last?.isError == true ? .alert : .idle), size: 38)
            HStack(spacing: 6) {
                if snapshot {
                    Text(chat.draft.isEmpty ? (chat.messages.isEmpty ? "Sor…" : "Devam et…") : chat.draft)
                        .font(.system(size: 12))
                        .foregroundStyle(chat.draft.isEmpty ? .white.opacity(0.35) : .white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(chat.messages.isEmpty ? "Sor…" : "Devam et…", text: $chat.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit(chat.sendDraft)
                }
                Button {
                    let base = chat.draft.isEmpty ? "" : chat.draft + " "
                    dictation.toggle { chat.draft = base + $0 }
                } label: {
                    Image(systemName: dictation.listening ? "mic.fill" : "mic")
                        .font(.system(size: 12))
                        .foregroundStyle(dictation.listening ? Palette.red : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(dictation.error ?? "Dikte (sağ tık: dil)")
                .contextMenu {
                    ForEach(Dictation.languages, id: \.id) { l in
                        Button {
                            dictation.language = l.id
                        } label: {
                            if dictation.language == l.id { Label(l.title, systemImage: "checkmark") } else { Text(l.title) }
                        }
                    }
                }
                Button {
                    if chat.streaming { chat.stop() } else { chat.sendDraft() }
                } label: {
                    Image(systemName: chat.streaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(canSend || chat.streaming ? .white : .white.opacity(0.25))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 12).padding(.trailing, 5).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.07)))
        }
    }

    private var canSend: Bool {
        !chat.draft.trimmingCharacters(in: .whitespaces).isEmpty || !app.attachments.isEmpty
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let streaming: Bool

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 4) {
                if !message.attachmentNames.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.attachmentNames, id: \.self) { AttachmentChip(name: $0) }
                    }
                }
                Text(message.text)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white.opacity(0.12)))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if message.text.isEmpty && streaming {
            TypingDots().frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(Self.markdown(message.text))
                .font(.system(size: 12))
                .foregroundStyle(message.isError ? Palette.red : .white.opacity(0.92))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(.white).frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
        }
    }
}

/// Gönderilmeyi bekleyen eklerin çipleri (kaldırılabilir).
struct AttachmentChips: View {
    @ObservedObject var app: AppState

    var body: some View {
        HStack(spacing: 5) {
            ForEach(app.attachments) { a in
                AttachmentChip(name: a.name) {
                    app.attachments.removeAll { $0.id == a.id }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct AttachmentChip: View {
    let name: String
    var remove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 5) {
            icon
            Text(name.count > 26 ? name.prefix(12) + "…" + name.suffix(11) : name)
                .font(.system(size: 10, weight: .medium)).lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .fixedSize()
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    @ViewBuilder private var icon: some View {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" {
            Image(systemName: "doc.richtext.fill").font(.system(size: 10)).foregroundStyle(Palette.red)
        } else if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains(ext) {
            Image(systemName: "photo.fill").font(.system(size: 10)).foregroundStyle(Palette.blue)
        } else {
            FileBadge(ext: ext)
        }
    }
}

/// Sohbet başlığında bağlı MCP araçları; tıklayınca Ayarlar → MCP açılır.
private struct MCPChip: View {
    @ObservedObject var hub: MCPHub
    let active: Bool

    var body: some View {
        if hub.toolCount > 0 {
            Button { SettingsWindowController.shared.show(section: "mcp") } label: {
                HStack(spacing: 4) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 9, weight: .semibold))
                    Text("\(hub.readyCount) MCP · \(hub.toolCount) araç").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(active ? .white.opacity(0.75) : .white.opacity(0.35))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(active ? "Bu sohbette MCP araçları kullanılabilir" : "MCP araçları yalnızca Claude seçiliyken kullanılır")
        }
    }
}
