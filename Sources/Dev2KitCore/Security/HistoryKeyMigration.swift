import Foundation

/// Geçmiş anahtarının dosyadan (`.history.key`) Keychain'e tek seferlik
/// taşınması (Developer ID ile imzalı sürüm).
///
/// `SecretMigration` ile aynı ilke: anahtar hedefe yazılır, bellek atlanarak
/// geri okunur; ANCAK aynıysa dosya silinir. Yarıda kesilirse dosya yerinde
/// kalır ve bir sonraki açılışta yeniden denenir. Hedefte FARKLI bir anahtar
/// varsa hangisinin geçerli olduğu bilinemez: ikisine de dokunulmaz.
public enum HistoryKeyMigration {
    /// Geçmiş anahtarının dosya adı (veri dizininin kökünde).
    public static let fileName = ".history.key"
    /// Keychain'deki kaydın adı.
    public static let keychainName = "history"

    /// Dosya yoksa `false` (taşınacak bir şey yok). Hata olursa dosya yerinde kalır.
    @discardableResult
    public static func migrate(directory: URL, to target: SecretStoreKey) throws -> Bool {
        let manager = FileManager.default
        let url = directory.appendingPathComponent(fileName)
        guard manager.fileExists(atPath: url.path) else { return false }
        guard let fileKey = try? Data(contentsOf: url), fileKey.count == 32 else {
            throw HistoryKeyMigrationError.unreadable(url.path)
        }
        switch try target.load(fresh: true) {
        case nil:
            try target.save(fileKey)
        case let existing? where existing == fileKey:
            break // önceki yarım deneme: Keychain'e yazılmış, dosya silinememiş
        case _?:
            throw HistoryKeyMigrationError.conflict
        }
        guard try target.load(fresh: true) == fileKey else {
            throw HistoryKeyMigrationError.verificationFailed
        }
        try manager.removeItem(at: url)
        return true
    }
}

public enum HistoryKeyMigrationError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case conflict
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return L10n.t("historyKey.migration.unreadable", path)
        case .conflict: return L10n.t("historyKey.migration.conflict")
        case .verificationFailed: return L10n.t("historyKey.migration.verify")
        }
    }
}
