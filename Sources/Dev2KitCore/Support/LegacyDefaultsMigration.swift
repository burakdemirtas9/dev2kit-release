import Foundation

/// Bundle kimliği değişince (`com.dev2kit.app` → `Dev2KitIdentity.bundleIdentifier`,
/// 2026-10-25, ilk Developer ID imzalı sürüm) macOS ayarları (UserDefaults) yeni
/// bir alana yazılır; eski alandaki dil, görünüm, sekme, pencere konumu gibi
/// tercihler kaybolmasın diye bir kez kopyalanır.
///
/// - Yalnızca yeni alanda OLMAYAN anahtarlar kopyalanır; yeni sürümde
///   değiştirilmiş bir değer ezilmez.
/// - Eski alan silinmez: eski sürüme dönülürse ayarları yerinde durur.
/// - Bir kez çalışır (işaret anahtarı); sonraki açılışlar dokunmaz.
public enum LegacyDefaultsMigration {
    public static let legacyDomain = "com.dev2kit.app"
    static let doneKey = "legacyDefaultsMigrated"

    /// - Returns: Kopyalanan anahtar sayısı (daha önce çalıştıysa 0).
    @discardableResult
    public static func migrate(from legacy: [String: Any]?, into defaults: UserDefaults) -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        var copied = 0
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(true, forKey: doneKey)
        return copied
    }
}
