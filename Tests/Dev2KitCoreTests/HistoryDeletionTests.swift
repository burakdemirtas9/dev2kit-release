import XCTest
@testable import Dev2KitCore

/// Geçmiş silinince eski şemadan kalan kopyalar da gider; saklama süresi
/// taşıma yedeğine de uygulanır. Değerler sentetik.
final class HistoryDeletionTests: XCTestCase {
    private var directory: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent("dev2kit-history-delete-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private func exists(_ name: String) -> Bool { manager.fileExists(atPath: url(name).path) }

    private func entry(_ name: String, environment: String? = nil, date: Date = Date()) -> HistoryEntry {
        HistoryEntry(date: date, requestID: UUID(), requestName: name, collectionName: nil, environmentName: environment,
                     method: .get, url: "https://api.example.test",
                     outcome: .completed(status: 200, duration: 0.1, byteCount: 1, redirectCount: 0),
                     snapshot: RequestModel(name: name))
    }

    /// Şema 1 dosyası yazar ve taşıtır: `history.v1.enc` yedeği oluşur.
    private func migratedStore(_ legacy: [HistoryEntry]) throws -> HistoryStore {
        try EncryptedJSONFile<[HistoryEntry]>(fileURL: url("history.enc"), keyURL: url(".history.key")).save(legacy)
        let store = HistoryStore(directory: directory)
        XCTAssertEqual(store.entries().count, legacy.count)
        store.waitForPendingWrites()
        XCTAssertTrue(exists("history.v1.enc"))
        return store
    }

    func testDeleteAllRemovesLegacyCopies() throws {
        let store = try migratedStore([entry("Eski")])
        try Data("okunamayan".utf8).write(to: url("history.enc.bozuk-20261020-101010"))

        store.deleteAll()
        store.waitForPendingWrites()
        XCTAssertFalse(exists("history"))
        XCTAssertFalse(exists("history.v1.enc"), "temizlenen geçmişin kopyası kalmaz")
        XCTAssertFalse(exists("history.enc.bozuk-20261020-101010"))
    }

    /// Taşıma yarım kaldıysa `history.enc` dizinle yan yana kalır. Temizlik
    /// onu bırakırsa sonraki açılışta taşınır ve silinen kayıtlar geri gelir.
    func testClearedHistoryDoesNotComeBackFromAnUnmigratedFile() throws {
        let store = HistoryStore(directory: directory)
        store.append(entry("Yeni"), settings: .default)
        store.waitForPendingWrites()
        try EncryptedJSONFile<[HistoryEntry]>(fileURL: url("history.enc"), keyURL: url(".history.key")).save([entry("Eski")])

        store.deleteAll()
        store.waitForPendingWrites()
        XCTAssertEqual(HistoryStore(directory: directory).entries(), [])
    }

    func testDeletingOneEntryRemovesTheMigrationBackup() throws {
        let store = try migratedStore([entry("Bir"), entry("İki")])
        let target = try XCTUnwrap(store.entries().first)
        store.delete(id: target.id)
        store.waitForPendingWrites()
        XCTAssertFalse(exists("history.v1.enc"))
        XCTAssertEqual(HistoryStore(directory: directory).entries().count, 1, "diğer kayıt dizinde kalır")
    }

    func testDeletingAnEnvironmentRemovesTheMigrationBackup() throws {
        let store = try migratedStore([entry("Prod", environment: "Prod"), entry("Dev", environment: "Dev")])
        store.deleteEntries(environmentName: "Prod")
        store.waitForPendingWrites()
        XCTAssertFalse(exists("history.v1.enc"))
        XCTAssertEqual(HistoryStore(directory: directory).entries().map(\.requestName), ["Dev"])
    }

    /// Okunamayan kopyalar yalnızca "tümünü temizle" ile gider: tek kayıt
    /// silmek kurtarma dosyasını yok etmez.
    func testDeletingOneEntryKeepsSetAsideCopies() throws {
        let store = try migratedStore([entry("Bir"), entry("İki")])
        try Data("okunamayan".utf8).write(to: url("history.enc.bozuk-20261020-101010"))
        store.delete(id: try XCTUnwrap(store.entries().first).id)
        store.waitForPendingWrites()
        XCTAssertTrue(exists("history.enc.bozuk-20261020-101010"))
    }

    func testMigrationBackupFollowsRetention() throws {
        let store = try migratedStore([entry("Eski")])
        var settings = HistorySettings.default
        settings.retentionDays = 30

        store.append(entry("Yeni"), settings: settings)
        store.waitForPendingWrites()
        XCTAssertTrue(exists("history.v1.enc"), "süresi dolmamış yedek kalır")

        let old = Date().addingTimeInterval(-31 * 86_400)
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: url("history.v1.enc").path)
        store.append(entry("Daha yeni"), settings: settings)
        store.waitForPendingWrites()
        XCTAssertFalse(exists("history.v1.enc"), "süresi dolan yedek silinir")
    }
}
