import Foundation

/// Veri dizininin yerleşimi (şema 2, 2026-10-21).
///
/// ```
/// <kök>/
///   store/
///     manifest.json            şema, sıra, etkin environment, dosya özetleri
///     collections/<uuid>.json  koleksiyon başına (istekleriyle)
///     environments.json        tüm environment'lar (az ve küçük)
///     settings.json            TLS profilleri, son gönderilen haller
///     journal.json             süren çok dosyalı işlem (bitince silinir)
///     staging/<işlem>/…        işlemin yeni dosyaları (commit'ten önce)
///   backups/<zaman>/           son sağlam anlık görüntüler
///   quarantine/<zaman>/        okunamayan dosyaların kopyası (silinmez)
///   workspace.json             şema 1 (tek dosya); geçişten sonra yedeğe taşınır
/// ```
/// Ayrım kullanım şekline göre: tek isteğin düzenlenmesi yalnızca kendi
/// koleksiyon dosyasını (ve manifest'i) yazar. Environment'lar ve ayarlar az
/// olduğu için tek dosyada; her alana ayrı dosya açılmadı.
public struct StoreLayout: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var store: URL { root.appendingPathComponent("store", isDirectory: true) }
    public var manifest: URL { store.appendingPathComponent("manifest.json") }
    var journal: URL { store.appendingPathComponent("journal.json") }
    var staging: URL { store.appendingPathComponent("staging", isDirectory: true) }
    public var backups: URL { root.appendingPathComponent("backups", isDirectory: true) }
    public var quarantine: URL { root.appendingPathComponent("quarantine", isDirectory: true) }
    /// Şema 1'in tek dosyası.
    public var legacyWorkspace: URL { root.appendingPathComponent("workspace.json") }
    /// Geçişin yarım kalabilen ara dizini; doğrulanınca `store` olur.
    var migrating: URL { root.appendingPathComponent("store.migrating", isDirectory: true) }

    static let environmentsPath = "environments.json"
    static let settingsPath = "settings.json"
    static func collectionPath(_ id: UUID) -> String { "collections/\(id.uuidString).json" }

    /// Manifest ve günlükteki göreli yol izin verilen biçimde mi. Bu yollarla
    /// dosya taşınıp siliniyor; bozulmuş ya da elle değiştirilmiş bir dosyadaki
    /// `../` dizin dışına çıkmasın (güvenlik incelemesi, 2026-10-21).
    static func isValidRelativePath(_ path: String) -> Bool {
        if path == environmentsPath || path == settingsPath { return true }
        guard path.hasPrefix("collections/"), path.hasSuffix(".json") else { return false }
        let stem = path.dropFirst("collections/".count).dropLast(".json".count)
        guard let id = UUID(uuidString: String(stem)) else { return false }
        return collectionPath(id) == path
    }
}

/// Hangi dosyanın hangi sürümünün geçerli olduğu. Son yazılan dosya:
/// çok dosyalı işlemde manifest en sonda yazılır.
struct StoreManifest: Codable, Equatable {
    static let currentSchema = 2

    var schemaVersion: Int
    var activeEnvironmentID: UUID?
    /// Koleksiyonların kenar çubuğundaki sırası.
    var collectionOrder: [UUID]
    /// Göreli yol → SHA-256 özeti.
    var files: [String: String]

    /// İçerik aynı mı (yazmaya gerek var mı).
    func sameContent(as other: StoreManifest?) -> Bool { self == other }
}

/// TLS profilleri ve son gönderilen haller: sık değişmeyen, az sayıda kayıt.
struct StoreSettings: Codable, Equatable {
    var tlsProfiles: [TLSProfile]
    var sentBaselines: [String: RequestModel]
}

/// Çok dosyalı işlemin kaydı. Bu dosyanın yazılması COMMIT noktasıdır:
/// yeni dosyaların hepsi önceden `staging/<id>/` altına diske yazılmıştır.
/// Yarıda kesilirse açılışta işlem İLERİ doğru tamamlanır.
struct StoreJournal: Codable {
    var id: UUID
    var writes: [String]
    var deletes: [String]
    var manifest: StoreManifest
}

/// Açılışta olan ve kullanıcıya söylenmesi gereken şeyler. Hiçbiri sessiz değil.
public enum StoreNotice: Equatable, Sendable {
    /// Şema 1 `workspace.json` taşındı; aslı yedekte.
    case migrated(backup: URL)
    /// Yarıda kalmış kayıt tamamlandı.
    case recoveredInterruptedSave
    /// Okunamayan dosyalar karantinaya kopyalandı, son sağlam yedek yüklendi.
    case restoredFromBackup(backup: URL, quarantine: URL)
    /// Yedek de yok/okunamıyor: okunabilen kısım yüklendi, okunamayanlar karantinada.
    case partiallyLoaded(lost: [String], quarantine: URL)
    /// Şema 1 dosyası okunamadı; kopyası alındı, boş workspace ile başlandı.
    case legacyUnreadable(backup: URL, reason: String)
}

public enum StoreError: Error, LocalizedError, Equatable {
    /// Daha yeni bir sürümün yazdığı veri: üzerine yazılmaz.
    case newerSchema(found: Int, supported: Int)
    /// Geçiş doğrulanamadı; eski dosya yerinde, yeni yapı etkin değil.
    case migrationVerificationFailed(String)
    /// Bekleyen işlem tamamlanamıyor; yeni kayıt yapılmaz.
    case journalUnrecoverable(String)

    public var errorDescription: String? {
        switch self {
        case .newerSchema(let found, let supported):
            return L10n.t("store.newerSchema", String(found), String(supported))
        case .migrationVerificationFailed(let detail):
            return L10n.t("store.migrationFailed", detail)
        case .journalUnrecoverable(let detail):
            return L10n.t("store.journalFailed", detail)
        }
    }
}
