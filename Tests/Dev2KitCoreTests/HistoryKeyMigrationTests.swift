import XCTest
@testable import Dev2KitCore

/// Geçmiş anahtarının dosyadan Keychain'e taşınması ve anahtar alınamayınca
/// geçmişin korunması. Hedef bellekteki depo: testler kullanıcının
/// Keychain'ine dokunmaz. Değerler sentetik.
final class HistoryKeyMigrationTests: XCTestCase {
    private var directory: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent("dev2kit-history-key-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: directory)
    }

    private var keyFile: URL { directory.appendingPathComponent(HistoryKeyMigration.fileName) }
    private var index: URL { directory.appendingPathComponent("history/index.enc") }

    private func entry(_ name: String) -> HistoryEntry {
        HistoryEntry(requestID: UUID(), requestName: name, collectionName: nil, environmentName: nil,
                     method: .get, url: "https://api.example.test",
                     outcome: .completed(status: 200, duration: 0.1, byteCount: 1, redirectCount: 0),
                     snapshot: RequestModel(name: name), responsePreview: "SYNTHETIC-PREVIEW")
    }

    /// Dosya anahtarıyla yazılmış bir geçmiş.
    @discardableResult
    private func fileBasedHistory(_ names: [String]) -> HistoryStore {
        let store = HistoryStore(directory: directory)
        names.forEach { store.append(entry($0), settings: .default) }
        store.waitForPendingWrites()
        return store
    }

    private func key(in store: InMemorySecretStore = InMemorySecretStore()) -> SecretStoreKey {
        SecretStoreKey(store: store, name: HistoryKeyMigration.keychainName)
    }

    private var asideFiles: [String] {
        let names = (try? manager.contentsOfDirectory(atPath: directory.appendingPathComponent("history").path)) ?? []
        return names.filter { $0.contains("bozuk") }
    }

    // MARK: - Taşıma

    func testMovesTheKeyAndHistoryStaysReadable() throws {
        fileBasedHistory(["Bir"])
        let target = key()
        XCTAssertTrue(try HistoryKeyMigration.migrate(directory: directory, to: target))
        XCTAssertFalse(manager.fileExists(atPath: keyFile.path), "anahtarın dosyada kopyası kalmaz")

        let reopened = HistoryStore(directory: directory, key: target)
        XCTAssertEqual(reopened.entries().map(\.requestName), ["Bir"])
        let id = try XCTUnwrap(reopened.entries().first?.id)
        XCTAssertEqual(reopened.fullEntry(id: id)?.responsePreview, "SYNTHETIC-PREVIEW")
        XCTAssertNil(reopened.keyFailure)
        XCTAssertFalse(try HistoryKeyMigration.migrate(directory: directory, to: target), "ikinci kez çalışmaz")
    }

    func testRetryAfterPartialMigrationRemovesTheFile() throws {
        fileBasedHistory(["Bir"])
        let fileKey = try Data(contentsOf: keyFile)
        let target = key(in: InMemorySecretStore(initial: [HistoryKeyMigration.keychainName: fileKey.base64EncodedString()]))
        XCTAssertTrue(try HistoryKeyMigration.migrate(directory: directory, to: target))
        XCTAssertFalse(manager.fileExists(atPath: keyFile.path))
    }

    func testDifferentKeyInTargetLeavesBothUntouched() throws {
        fileBasedHistory(["Bir"])
        let other = Data(repeating: 7, count: 32).base64EncodedString()
        let secrets = InMemorySecretStore(initial: [HistoryKeyMigration.keychainName: other])
        XCTAssertThrowsError(try HistoryKeyMigration.migrate(directory: directory, to: key(in: secrets))) { error in
            XCTAssertEqual(error as? HistoryKeyMigrationError, .conflict)
        }
        XCTAssertTrue(manager.fileExists(atPath: keyFile.path))
        XCTAssertEqual(try secrets.secret(forName: HistoryKeyMigration.keychainName), other)
    }

    /// Hedef yazılanı geri vermiyorsa (Keychain hatası) dosya silinmez.
    func testVerificationFailureKeepsTheFile() throws {
        final class DroppingStore: SecretStore, @unchecked Sendable {
            func setSecret(_ value: String, forName name: String) throws {}
            func secret(forName name: String) throws -> String? { nil }
            func deleteSecret(forName name: String) throws {}
            func listSecretNames() throws -> [String] { [] }
        }
        fileBasedHistory(["Bir"])
        let target = SecretStoreKey(store: DroppingStore(), name: HistoryKeyMigration.keychainName)
        XCTAssertThrowsError(try HistoryKeyMigration.migrate(directory: directory, to: target)) { error in
            XCTAssertEqual(error as? HistoryKeyMigrationError, .verificationFailed)
        }
        XCTAssertTrue(manager.fileExists(atPath: keyFile.path))
    }

    func testUnreadableKeyFileIsKept() throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("kısa".utf8).write(to: keyFile)
        XCTAssertThrowsError(try HistoryKeyMigration.migrate(directory: directory, to: key()))
        XCTAssertEqual(try Data(contentsOf: keyFile), Data("kısa".utf8))
    }

    func testNothingToMigrate() throws {
        XCTAssertFalse(try HistoryKeyMigration.migrate(directory: directory, to: key()))
    }

    // MARK: - Anahtar secret deposunda

    func testKeyInSecretStoreWritesNoKeyFile() throws {
        let target = key()
        let store = HistoryStore(directory: directory, key: target)
        store.append(entry("Bir"), settings: .default)
        store.waitForPendingWrites()
        XCTAssertFalse(manager.fileExists(atPath: keyFile.path))
        XCTAssertEqual(HistoryStore(directory: directory, key: target).entries().map(\.requestName), ["Bir"])
    }

    // MARK: - Anahtar alınamayınca

    /// Önceden okunamayan anahtar "bozuk dizin" sayılıp dizin kenara alınıyordu;
    /// anahtar sonradan gelince yeni dizin eskisinin üzerine yazılabilirdi.
    func testMissingKeyDoesNotSetAsideOrOverwriteTheHistory() throws {
        fileBasedHistory(["Bir", "İki"])
        try manager.removeItem(at: keyFile)
        let sealed = try Data(contentsOf: index)

        let reopened = HistoryStore(directory: directory)
        XCTAssertEqual(reopened.entries(), [])
        XCTAssertNotNil(reopened.keyFailure)
        reopened.append(entry("Yeni"), settings: .default)
        reopened.deleteEntries(environmentName: nil)
        reopened.waitForPendingWrites()

        XCTAssertEqual(try Data(contentsOf: index), sealed, "dizin değişmez")
        XCTAssertEqual(asideFiles, [], "dizin kenara alınmaz")
        XCTAssertFalse(manager.fileExists(atPath: keyFile.path), "yeni anahtar üretilmez")
    }

    func testUnavailableKeychainDoesNotTouchTheHistory() throws {
        final class LockedStore: SecretStore, @unchecked Sendable {
            struct Locked: Error {}
            func setSecret(_ value: String, forName name: String) throws { throw Locked() }
            func secret(forName name: String) throws -> String? { throw Locked() }
            func deleteSecret(forName name: String) throws {}
            func listSecretNames() throws -> [String] { [] }
        }
        let working = key()
        let store = HistoryStore(directory: directory, key: working)
        store.append(entry("Bir"), settings: .default)
        store.waitForPendingWrites()
        let sealed = try Data(contentsOf: index)

        let locked = HistoryStore(directory: directory, key: SecretStoreKey(store: LockedStore(), name: "history"))
        XCTAssertEqual(locked.entries(), [])
        XCTAssertNotNil(locked.keyFailure)
        locked.append(entry("Yeni"), settings: .default)
        locked.waitForPendingWrites()
        XCTAssertEqual(try Data(contentsOf: index), sealed)
        XCTAssertEqual(asideFiles, [])
        // Keychain yeniden açılınca geçmiş yerinde.
        XCTAssertEqual(HistoryStore(directory: directory, key: working).entries().map(\.requestName), ["Bir"])
    }
}
