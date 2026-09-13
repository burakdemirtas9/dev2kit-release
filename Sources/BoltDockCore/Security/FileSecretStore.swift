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

    private func loadKey() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try FileManager.default.createDirectory(
            at: keyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }

    private func loadAll() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: fileURL))
        let plain = try AES.GCM.open(sealed, using: loadKey())
        return try JSONDecoder().decode([String: String].self, from: plain)
    }

    private func saveAll(_ secrets: [String: String]) throws {
        let plain = try JSONEncoder().encode(secrets)
        let sealed = try AES.GCM.seal(plain, using: loadKey())
        guard let combined = sealed.combined else {
            throw SecretStoreError.encodingFailed
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try combined.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
