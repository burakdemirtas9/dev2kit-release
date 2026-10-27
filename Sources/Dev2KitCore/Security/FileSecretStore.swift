import CryptoKit
import Foundation

/// AES-GCM ile şifrelenmiş, dosya tabanlı secret deposu.
///
/// Neden Keychain değil: imzasız geliştirme binary'si her derlemede değiştiği
/// için macOS Keychain her rebuild'de kullanıcıdan parola istiyor. Bu depo
/// parola sormaz; secret'lar `secrets.enc` içinde şifreli durur, anahtar ise
/// yalnızca kullanıcının okuyabildiği (0600) ayrı bir dosyadadır.
/// Not: Bu model dosya sızıntılarına (git, yedek) karşı korur; imzalı .app
/// dağıtımında `KeychainSecretStore`'a geçilmesi önerilir.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let fileURL: URL
    private let keyURL: URL
    private let lock = NSLock()
    /// Önceki sürümün yazdığı dosyalar ilk erişimde yedek dışı işaretlenir.
    private var checkedBackupExclusion = false

    public init(directory: URL? = nil) {
        let dir = directory ?? AppPaths.supportDirectory
        self.fileURL = dir.appendingPathComponent("secrets.enc")
        self.keyURL = dir.appendingPathComponent(".secrets.key")
    }

    public func setSecret(_ value: String, forName name: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = try loadAll()
        all[name] = value
        try saveAll(all)
    }

    public func secret(forName name: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try loadAll()[name]
    }

    public func deleteSecret(forName name: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = try loadAll()
        all.removeValue(forKey: name)
        try saveAll(all)
    }

    public func listSecretNames() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return try loadAll().keys.sorted()
    }

    // MARK: - Şifreleme

    /// Format değişmedi: aynı dosya, aynı anahtar, aynı AES-GCM sarmalama.
    /// Yalnızca kod geçmiş kaydıyla paylaşılan yardımcıya taşındı.
    private var file: EncryptedJSONFile<[String: String]> {
        EncryptedJSONFile(fileURL: fileURL, keyURL: keyURL)
    }

    private func loadAll() throws -> [String: String] {
        if !checkedBackupExclusion {
            file.excludeExistingFromBackup()
            checkedBackupExclusion = true
        }
        return try file.load(fallback: [:])
    }

    private func saveAll(_ secrets: [String: String]) throws {
        try file.save(secrets)
    }
}
