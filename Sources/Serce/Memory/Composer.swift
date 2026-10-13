import AppKit
import UniformTypeIdentifiers

/// Oturumlara yazılan mesaj taslakları (metin + görseller). Görünümün dışında tutulur: ada kapanıp açılsa,
/// dosya seçme penceresi açılsa da kaybolmaz. Oturum çalışırken gönderilen mesaj sıraya alınır, bitince gider.
@MainActor final class ComposerStore: ObservableObject {
    static let shared = ComposerStore()
    static let maxImages = 5

    struct Draft {
        var text = ""
        var images: [Data] = []
        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }
    }

    @Published var drafts: [String: Draft] = [:]
    /// Oturum bitince gönderilecek mesajlar.
    @Published private(set) var queued: [String: Draft] = [:]
    @Published private(set) var errors: [String: String] = [:]

    func draft(_ sid: String) -> Draft { drafts[sid] ?? Draft() }

    func setText(_ text: String, for sid: String) { drafts[sid, default: Draft()].text = text }

    func addImage(_ data: Data, to sid: String) {
        guard draft(sid).images.count < Self.maxImages else { return }
        drafts[sid, default: Draft()].images.append(data)
    }

    func removeImage(at i: Int, from sid: String) {
        guard draft(sid).images.indices.contains(i) else { return }
        drafts[sid]?.images.remove(at: i)
    }

    /// Gönder; oturum çalışıyorsa sıraya al. Dönen metin hata ya da bilgi notudur.
    func submit(for s: AgentSession) -> String? {
        let d = draft(s.id)
        guard !d.isEmpty else { return nil }
        if s.status == .working || AgentRunner.shared.isRunning(s.id) {
            queued[s.id] = d
            drafts[s.id] = Draft()
            return nil
        }
        if let err = send(d, to: s) { return err }
        drafts[s.id] = Draft()
        return nil
    }

    /// Hazır bir metni gönder (başka oturumdan aktarma); oturum çalışıyorsa sıraya alır, kullanıcının taslağına dokunmaz.
    func enqueue(_ text: String, for s: AgentSession) -> String? {
        if s.status == .working || AgentRunner.shared.isRunning(s.id) {
            if let old = queued[s.id], !old.text.isEmpty {
                queued[s.id]?.text = old.text + "\n\n" + text
            } else {
                queued[s.id] = Draft(text: text)
            }
            return nil
        }
        errors[s.id] = nil
        return AgentRunner.shared.send(text, to: s)
    }

    func cancelQueued(_ sid: String) {
        if let d = queued.removeValue(forKey: sid) { drafts[sid] = d }
    }

    /// Oturum durduğunda (Stop) ya da Pepe'nin çalıştırması bitince sıradaki mesajı gönderir.
    func flush(_ sid: String) {
        guard let d = queued[sid], let s = AppState.shared.store.sessions.first(where: { $0.id == sid }),
              s.status != .working, !AgentRunner.shared.isRunning(sid) else { return }
        queued[sid] = nil
        if let err = send(d, to: s) {
            errors[sid] = err
            drafts[sid] = d
        }
    }

    private func send(_ d: Draft, to s: AgentSession) -> String? {
        let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        errors[s.id] = nil
        return AgentRunner.shared.send(text.isEmpty ? "Bu görsele bak." : text, images: d.images, to: s)
    }

    // MARK: - Panodan / sürüklemeden görsel

    /// Panoda görsel (ya da görsel dosyası) varsa ekler; eklediyse true.
    func pasteImages(into sid: String) -> Bool {
        let pb = NSPasteboard.general
        var added = false
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls where Self.isImage(url) {
                if let d = try? Data(contentsOf: url) { addImage(d, to: sid); added = true }
            }
        }
        if !added, let img = NSImage(pasteboard: pb), pb.string(forType: .string) == nil, let tiff = img.tiffRepresentation {
            addImage(tiff, to: sid)
            added = true
        }
        return added
    }

    func addDropped(_ providers: [NSItemProvider], to sid: String) {
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, Self.isImage(url), let d = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in ComposerStore.shared.addImage(d, to: sid) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage, let tiff = img.tiffRepresentation else { return }
                    Task { @MainActor in ComposerStore.shared.addImage(tiff, to: sid) }
                }
            }
        }
    }

    nonisolated static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }
}
