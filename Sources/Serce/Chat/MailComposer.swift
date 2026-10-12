import AppKit

/// Mail'de e-posta taslağı açar; asla kendisi göndermez. Gönder'e kullanıcı basar.
/// Sesli asistan da bunu çağırır: MailComposer.compose(to:subject:body:attachments:)
@MainActor enum MailComposer {
    @discardableResult
    static func compose(to: [String], subject: String, body: String, attachments: [URL]) -> Bool {
        guard let service = NSSharingService(named: .composeEmail) else { return false }
        service.recipients = to
        service.subject = subject
        var items: [Any] = []
        if !body.isEmpty { items.append(body) }
        items.append(contentsOf: attachments as [Any])
        guard service.canPerform(withItems: items) else { return false }
        service.perform(withItems: items)
        return true
    }
}
