import Foundation
import Security

/// Şifreli dosya deposundan (`secrets.enc` + `.secrets.key`) Keychain'e
/// tek seferlik geçiş (2026-10-21).
///
/// Her secret hedefe yazılır ve geri okunarak doğrulanır; ANCAK hepsi
/// tutarsa eski dosyalar silinir (secret'ın düz dosyada kopyası kalmasın).
/// Yarıda kesilirse eski dosyalar yerinde kalır ve bir sonraki açılışta
/// yeniden denenir: aynı adlara aynı değerler yazılır, çoğalma olmaz.
///
/// Keychain'de aynı adla FARKLI değer varsa Keychain'deki kazanır (kullanıcı
/// kararı, 2026-11-01). Dosya ezmiyordu ama çakışmada geçiş her açılışta
/// duruyor, oturum bayat dosya değerleriyle açılıyordu. Artık eksikler taşınır,
/// eski dosya çifti şifreli yedeğe (`secrets.conflict.enc`) alınır; geçiş
/// tamamlanır ve çakışan adlar kullanıcıya bildirilir.
public enum SecretMigration {
    public struct Report: Equatable, Sendable {
        public let migrated: Int
        /// Keychain'de farklı değeri olduğu için Keychain'deki değeri korunan adlar.
        public let keptInKeychain: [String]
    }

    /// Çakışmada eski dosyaların yedek adları (bir önceki yedeğin yerine geçer).
    public static let conflictBackupName = "secrets.conflict.enc"
    static let conflictBackupKeyName = ".secrets.conflict.key"

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
        var missing: [String] = []
        var kept: [String] = []
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            switch try target.secret(forName: name) {
            case nil: missing.append(name)
            case let existing? where existing == value: break
            case _?: kept.append(name)
            }
        }
        for name in missing {
            try target.setSecret(values[name] ?? "", forName: name)
        }
        for (name, value) in values where !kept.contains(name) {
            guard try target.secret(forName: name) == value else {
                throw SecretMigrationError.verificationFailed(name)
            }
        }
        if kept.isEmpty {
            try manager.removeItem(at: file)
            try? manager.removeItem(at: key)
        } else {
            try backUp(file: file, key: key, in: legacyDirectory)
        }
        return Report(migrated: values.count - kept.count, keptInKeychain: kept)
    }

    /// Dosyadaki farklı değerler kaybolmasın: dosya ve anahtarı birlikte yedek
    /// adına taşınır (şifreli kalır). Anahtar taşınamazsa dosya geri konur;
    /// yarım yedek bırakılmaz.
    private static func backUp(file: URL, key: URL, in directory: URL) throws {
        let manager = FileManager.default
        let backupFile = directory.appendingPathComponent(conflictBackupName)
        let backupKey = directory.appendingPathComponent(conflictBackupKeyName)
        for url in [backupFile, backupKey] where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        try manager.moveItem(at: file, to: backupFile)
        guard manager.fileExists(atPath: key.path) else { return }
        do {
            try manager.moveItem(at: key, to: backupKey)
        } catch {
            try? manager.moveItem(at: backupFile, to: file)
            throw error
        }
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
