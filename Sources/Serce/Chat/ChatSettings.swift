import SwiftUI

/// Ayarlar → Sohbet: anahtarlar, yerel sunucular, varsayılan sağlayıcı ve model, dikte dili.
struct ChatSettingsView: View {
    @ObservedObject var chat = ChatSession.shared
    @ObservedObject var dictation = Dictation.shared
    @AppStorage("ollamaURL") private var ollamaURL = "http://localhost:11434"
    @AppStorage("lmstudioURL") private var lmstudioURL = "http://localhost:1234"

    var body: some View {
        SettingsGroup(title: "Varsayılan", footer: "Notch'taki model etiketine tıklayarak da değiştirebilirsin.") {
            Picker("Sağlayıcı", selection: Binding(get: { chat.provider }, set: { chat.select($0) })) {
                ForEach(ChatProvider.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Text("Model").frame(width: 150, alignment: .leading)
                TextField("model kimliği", text: $chat.model).textFieldStyle(.roundedBorder)
                Menu("Öneriler") {
                    ForEach(chat.provider.suggestedModels + (chat.localModels[chat.provider] ?? []), id: \.self) { m in
                        Button(m) { chat.model = m }
                    }
                }
                .fixedSize()
            }
        }
        SettingsGroup(title: "Bulut anahtarları", footer: "Anahtarlar bu Mac'in Anahtar Zinciri'nde saklanır; yalnızca ilgili servise gönderilir. Sesli asistan da aynı anahtarları kullanır.") {
            SecretField(title: "Anthropic (Claude)", key: "anthropic", placeholder: "sk-ant-…")
            SecretField(title: "OpenAI", key: "openai", placeholder: "sk-…")
            SecretField(title: "Google Gemini", key: "gemini", placeholder: "AIza…")
        }
        SettingsGroup(title: "Yerel modeller", footer: "Bu Mac'te çalışan sunucuya bağlanır; anahtar gerekmez.") {
            HStack {
                Text("Ollama").frame(width: 150, alignment: .leading)
                TextField("http://localhost:11434", text: $ollamaURL).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("LM Studio").frame(width: 150, alignment: .leading)
                TextField("http://localhost:1234", text: $lmstudioURL).textFieldStyle(.roundedBorder)
            }
        }
        SettingsGroup(title: "Dikte", footer: "Sohbetteki mikrofon düğmesine sağ tıklayarak da dil seçebilirsin. Tanıma destekleniyorsa cihaz üstünde yapılır.") {
            Picker("Dil", selection: Binding(get: { dictation.language }, set: { dictation.language = $0 })) {
                ForEach(Dictation.languages, id: \.id) { Text($0.title).tag($0.id) }
            }
        }
    }
}

enum ChatFeature {
    @MainActor static func register(_ app: AppState) {
        SettingsRegistry.shared.add(SettingsSection(id: "sohbet", title: "Sohbet", icon: "bubble.left.and.bubble.right", order: 30) {
            AnyView(ChatSettingsView())
        })
    }
}
