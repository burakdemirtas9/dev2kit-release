import XCTest
@testable import Dev2KitCore

/// Vault ve geçmiş dosyaları (veri + anahtar) Time Machine yedeğine gitmez;
/// workspace gitmeye devam eder. Değerler sentetik.
final class BackupExclusionTests: XCTestCase {
    private var directory: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent("dev2kit-backup-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: directory)
    }

    /// Her seferinde yeni URL: `URL` özellik değerlerini önbelleğe alır.
    private func isExcluded(_ name: String) throws -> Bool {
        let url = URL(fileURLWithPath: directory.appendingPathComponent(name).path)
        return try XCTUnwrap(url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
    }

    /// Önceki sürümün yazdığı, işaretsiz dosyayı taklit eder.
    private func clearMark(_ name: String) throws {
        var url = directory.appendingPathComponent(name)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try url.setResourceValues(values)
        XCTAssertFalse(try isExcluded(name))
    }

    private func entry(_ name: String) -> HistoryEntry {
        HistoryEntry(requestID: UUID(), requestName: name, collectionName: nil, environmentName: nil,
                     method: .get, url: "https://api.example.test",
                     outcome: .completed(status: 200, duration: 0.1, byteCount: 1, redirectCount: 0),
                     snapshot: RequestModel(name: name), responsePreview: "SYNTHETIC")
    }

    // MARK: - Vault (imzasız derleme)

    func testVaultDataAndKeyAreExcluded() throws {
        try FileSecretStore(directory: directory).setSecret("SYNTHETIC-1", forName: "api")
        XCTAssertTrue(try isExcluded("secrets.enc"))
        XCTAssertTrue(try isExcluded(".secrets.key"))
    }

    /// Her kayıtta dosya yenisiyle değişir; işaret kaybolmamalı.
    func testMarkSurvivesRewrites() throws {
        let store = FileSecretStore(directory: directory)
        try store.setSecret("SYNTHETIC-1", forName: "api")
        try store.setSecret("SYNTHETIC-2", forName: "db")
        try store.deleteSecret(forName: "api")
        XCTAssertTrue(try isExcluded("secrets.enc"))
    }

    func testVaultFilesOfAnOlderVersionAreMarkedOnFirstAccess() throws {
        try FileSecretStore(directory: directory).setSecret("SYNTHETIC-1", forName: "api")
        try clearMark("secrets.enc")
        try clearMark(".secrets.key")

        _ = try FileSecretStore(directory: directory).listSecretNames()
        XCTAssertTrue(try isExcluded("secrets.enc"))
        XCTAssertTrue(try isExcluded(".secrets.key"))
    }

    // MARK: - Geçmiş

    func testHistoryFilesAndKeyAreExcluded() throws {
        let store = HistoryStore(directory: directory)
        store.append(entry("Bir"), settings: .default)
        store.waitForPendingWrites()
        store.append(entry("İki"), settings: .default)
        store.waitForPendingWrites()

        XCTAssertTrue(try isExcluded(".history.key"))
        XCTAssertTrue(try isExcluded("history/index.enc"))
        XCTAssertTrue(try isExcluded("history/index.prev.enc"))
        let bodies = try manager.contentsOfDirectory(atPath: directory.appendingPathComponent("history/bodies").path)
        XCTAssertFalse(bodies.isEmpty)
        for name in bodies { XCTAssertTrue(try isExcluded("history/bodies/\(name)"), name) }
    }

    func testHistoryFilesOfAnOlderVersionAreMarkedOnLoad() throws {
        let store = HistoryStore(directory: directory)
        store.append(entry("Bir"), settings: .default)
        store.waitForPendingWrites()
        try Data("eski".utf8).write(to: directory.appendingPathComponent("history.v1.enc"))
        try clearMark(".history.key")
        try clearMark("history")

        let reopened = HistoryStore(directory: directory)
        _ = reopened.entries()
        reopened.waitForPendingWrites()
        XCTAssertTrue(try isExcluded(".history.key"))
        XCTAssertTrue(try isExcluded("history"), "dizin işaretliyse içindeki her şey yedek dışı")
        XCTAssertTrue(try isExcluded("history.v1.enc"))
    }

    // MARK: - Workspace yedeğe gitmeye devam eder

    func testPlainAtomicWritesStayInBackups() throws {
        try AtomicFile.write(Data("{}".utf8), to: directory.appendingPathComponent("workspace.json"))
        XCTAssertFalse(try isExcluded("workspace.json"))
    }
}
