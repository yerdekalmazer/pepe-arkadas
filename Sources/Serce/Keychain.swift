import Foundation
import Security

/// Gizli anahtarlar (API anahtarları, OAuth jetonları): ~/Library/Application Support/Serce/anahtarlar.json,
/// yalnızca kullanıcının okuyabildiği (0600) bir dosya — gh, Claude Code ve Trello'nun yaptığı gibi.
///
/// Neden Keychain değil: Keychain her kaydı onu oluşturan uygulama imzasına bağlar. Serçe her derlendiğinde
/// (ve test için komut satırından çalıştırıldığında) macOS her kayıt için ayrı ayrı oturum parolası soruyordu.
/// Ad "Keychain" olarak kaldı ki çağıran yerler değişmesin. Eski Keychain kayıtları kendiliğinden okunmaz
/// (okumak parola sordurur); Ayarlar → Genel'deki "Eski anahtarları taşı" ile istenirse bir kez taşınır.
enum Keychain {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var store: [String: String]?

    private static var url: URL { Support.dir.appendingPathComponent("anahtarlar.json") }

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let v = load()[key]
        return (v?.isEmpty ?? true) ? nil : v
    }

    static func set(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        var s = load()
        if let value, !value.isEmpty { s[key] = value } else { s.removeValue(forKey: key) }
        store = s
        save(s)
    }

    /// Kilit tutulurken çağrılır.
    private static func load() -> [String: String] {
        if let store { return store }
        let s = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        store = s
        return s
    }

    private static func save(_ s: [String: String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(s) else { return }
        // Önce 0600 izinli boş dosya, sonra içerik: dosya bir an bile başkasınca okunabilir olmasın.
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? d.write(to: url)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Eski Keychain kayıtları (yalnızca kullanıcı isteyince)

    private static let legacyService = "com.tahayerdekalmazer.serce"

    /// Eski sürümlerin Keychain'e yazdığı kayıtların adları (okumaz, parola sordurmaz).
    static func legacyAccounts() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Eski kayıtları dosyaya taşır ve Keychain'den siler. macOS her kayıt için bir kez parola sorabilir.
    @discardableResult
    static func importLegacy() -> Int {
        var moved = 0
        for account in legacyAccounts() {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService,
                                       kSecAttrAccount as String: account]
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
               let value = String(data: data, encoding: .utf8), !value.isEmpty {
                if get(account) == nil { set(account, value) }
                moved += 1
            }
            SecItemDelete(base as CFDictionary)
        }
        return moved
    }
}
