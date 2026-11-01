import XCTest
@testable import Dev2KitCore

/// Şifreli dosyadan Keychain'e geçiş. Hedef bellekteki depo: testler
/// kullanıcının Keychain'ine dokunmaz. Değerler sentetik.
final class SecretMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-secrets-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func legacy(_ values: [String: String]) throws {
        let store = FileSecretStore(directory: directory)
        for (name, value) in values { try store.setSecret(value, forName: name) }
    }

    private var legacyFiles: [String] {
        ["secrets.enc", ".secrets.key"].filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    func testMigratesEverySecretAndRemovesTheFiles() throws {
        try legacy(["api": "SYNTHETIC-1", "db": "SYNTHETIC-2"])
        let target = InMemorySecretStore()
        let report = try SecretMigration.migrate(legacyDirectory: directory, to: target)
        XCTAssertEqual(report?.migrated, 2)
        XCTAssertEqual(try target.secret(forName: "api"), "SYNTHETIC-1")
        XCTAssertEqual(try target.secret(forName: "db"), "SYNTHETIC-2")
        XCTAssertEqual(legacyFiles, [], "secret'ın düz dosyada kopyası kalmaz")
        XCTAssertNil(try SecretMigration.migrate(legacyDirectory: directory, to: target), "ikinci kez çalışmaz")
    }

    func testRetryAfterPartialMigrationDoesNotDuplicate() throws {
        try legacy(["api": "SYNTHETIC-1", "db": "SYNTHETIC-2"])
        let target = InMemorySecretStore(initial: ["api": "SYNTHETIC-1"]) // önceki yarım deneme
        XCTAssertEqual(try SecretMigration.migrate(legacyDirectory: directory, to: target)?.migrated, 2)
        XCTAssertEqual(try target.listSecretNames(), ["api", "db"])
    }

    /// Hedef yazılanı geri vermiyorsa (Keychain hatası) dosyalar silinmez.
    func testVerificationFailureKeepsTheFiles() throws {
        final class DroppingStore: SecretStore, @unchecked Sendable {
            func setSecret(_ value: String, forName name: String) throws {}
            func secret(forName name: String) throws -> String? { nil }
            func deleteSecret(forName name: String) throws {}
            func listSecretNames() throws -> [String] { [] }
        }
        try legacy(["api": "SYNTHETIC-1"])
        XCTAssertThrowsError(try SecretMigration.migrate(legacyDirectory: directory, to: DroppingStore()))
        XCTAssertEqual(legacyFiles, ["secrets.enc", ".secrets.key"])
    }

    /// Keychain'de farklı değer varsa Keychain kazanır (kullanıcı kararı,
    /// 2026-11-01): ezilmez, eksikler taşınır, eski dosya çifti şifreli yedeğe
    /// alınır ve geçiş tamamlanır. Önceden her açılışta durup bayat dosyayla
    /// açılıyordu.
    func testKeychainWinsOnConflictAndTheFileIsBackedUp() throws {
        try legacy(["api": "SYNTHETIC-OLD", "db": "SYNTHETIC-2"])
        let target = InMemorySecretStore(initial: ["api": "SYNTHETIC-NEW"])
        let report = try XCTUnwrap(try SecretMigration.migrate(legacyDirectory: directory, to: target))
        XCTAssertEqual(report, SecretMigration.Report(migrated: 1, keptInKeychain: ["api"]))
        XCTAssertEqual(try target.secret(forName: "api"), "SYNTHETIC-NEW", "Keychain'deki ezilmez")
        XCTAssertEqual(try target.secret(forName: "db"), "SYNTHETIC-2", "eksik olan taşınır")
        XCTAssertEqual(legacyFiles, [], "geçiş tamamlanır, döngü biter")
        XCTAssertFalse(SecretMigration.isPending(legacyDirectory: directory))

        // Yedek okunabilir: dosyadaki değer kaybolmadı.
        let backup = directory.appendingPathComponent("restore")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appendingPathComponent(SecretMigration.conflictBackupName),
                                         to: backup.appendingPathComponent("secrets.enc"))
        try FileManager.default.copyItem(at: directory.appendingPathComponent(".secrets.conflict.key"),
                                         to: backup.appendingPathComponent(".secrets.key"))
        XCTAssertEqual(try FileSecretStore(directory: backup).secret(forName: "api"), "SYNTHETIC-OLD")
    }

    func testUnreadableKeyKeepsTheFiles() throws {
        try legacy(["api": "SYNTHETIC-1"])
        try Data("kısa".utf8).write(to: directory.appendingPathComponent(".secrets.key"))
        XCTAssertThrowsError(try SecretMigration.migrate(legacyDirectory: directory, to: InMemorySecretStore()))
        XCTAssertEqual(legacyFiles, ["secrets.enc", ".secrets.key"])
    }

    func testNothingToMigrate() throws {
        XCTAssertNil(try SecretMigration.migrate(legacyDirectory: directory, to: InMemorySecretStore()))
        XCTAssertFalse(SecretMigration.isPending(legacyDirectory: directory))
    }
}
