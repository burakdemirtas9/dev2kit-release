import Foundation
import Security

/// Şifreli dosya deposundan (`secrets.enc` + `.secrets.key`) Keychain'e
/// tek seferlik geçiş (2026-10-21).
///
/// Her secret hedefe yazılır ve geri okunarak doğrulanır; ANCAK hepsi
/// tutarsa eski dosyalar silinir (secret'ın düz dosyada kopyası kalmasın).
/// Yarıda kesilirse eski dosyalar yerinde kalır ve bir sonraki açılışta
/// yeniden denenir: aynı adlara aynı değerler yazılır, çoğalma olmaz.
public enum SecretMigration {
    public struct Report: Equatable, Sendable {
        public let migrated: Int
    }

    /// Eski depo yoksa `nil`. Okunamazsa ya da doğrulanamazsa hata; eski
    /// dosyalar yerinde kalır.
    public static func migrate(legacyDirectory: URL, to target: SecretStore) throws -> Report? {
        let manager = FileManager.default
        let file = legacyDirectory.appendingPathComponent("secrets.enc")
        let key = legacyDirectory.appendingPathComponent(".secrets.key")
        guard manager.fileExists(atPath: file.path) else {
            // Veri yok, anahtar artık: tek başına bir işe yaramaz.
            if manager.fileExists(atPath: key.path) { try? manager.removeItem(at: key) }
            return nil
        }
        let legacy = FileSecretStore(directory: legacyDirectory)
        var values: [String: String] = [:]
        for name in try legacy.listSecretNames() {
            values[name] = try legacy.secret(forName: name)
        }
        for (name, value) in values where try target.secret(forName: name) != value {
            try target.setSecret(value, forName: name)
        }
        for (name, value) in values {
            guard try target.secret(forName: name) == value else {
                throw SecretMigrationError.verificationFailed(name)
            }
        }
        try manager.removeItem(at: file)
        try? manager.removeItem(at: key)
        return Report(migrated: values.count)
    }

    /// Eski depo henüz taşınmadı mı.
    public static func isPending(legacyDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: legacyDirectory.appendingPathComponent("secrets.enc").path)
    }
}

public enum SecretMigrationError: Error, LocalizedError, Equatable {
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let name): return L10n.t("secrets.migration.verify", name)
        }
    }
}

/// Çalışan uygulamanın imzası.
public enum CodeSigningStatus {
    /// Developer ID gibi ekip kimliği taşıyan bir imza mı.
    ///
    /// Keychain, secret'a erişen uygulamayı imzasıyla tanır. Ad-hoc (ya da
    /// kendinden imzalı) derlemenin kimliği her güncellemede değişir ve macOS
    /// kullanıcıdan parola ister. Kurumsal ortamda parola/yönetici onayı
    /// isteyen hiçbir akış olmamalı (kullanıcı kararı, 2026-10-21): Keychain
    /// yalnızca kimliği sabit, ekip kimlikli imzada kullanılır.
    public static var hasTeamIdentity: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return false }
        return (info[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
    }
}
