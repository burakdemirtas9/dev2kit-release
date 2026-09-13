import Foundation

/// Uygulamanın veri dizini ve eski sürümden taşıma.
///
/// Uygulama "Vaultman" adıyla başlayıp "BoltDock" oldu. Kullanıcının mevcut
/// koleksiyonları ve şifreli vault'u eski dizinde kalmasın diye, yeni dizin
/// henüz yoksa eski dizin bir kez taşınır.
public enum AppPaths {
    private static let legacyName = "Vaultman"
    private static let currentName = "BoltDock"

    /// `static let` tembel ve thread-safe: taşıma süreç başına en fazla bir kez çalışır.
    private static let migrationDone: Bool = {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let legacy = base.appendingPathComponent(legacyName)
        let current = base.appendingPathComponent(currentName)
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: current.path) else {
            return false
        }
        // Taşıma başarısız olursa uygulama boş workspace ile açılır; eski dizin
        // yerinde kalacağı için veri kaybı olmaz.
        try? fileManager.moveItem(at: legacy, to: current)
        return true
    }()

    /// ~/Library/Application Support/BoltDock — ilk erişimde taşımayı tetikler.
    public static var supportDirectory: URL {
        _ = migrationDone
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(currentName)
    }
}
