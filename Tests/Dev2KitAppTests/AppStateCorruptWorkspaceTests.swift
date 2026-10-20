import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Okunamayan workspace.json: uyarı gösterilirken veri ezilmiş olmamalı.
@MainActor
final class AppStateCorruptWorkspaceTests: XCTestCase {
    private var directory: URL!
    private var store: WorkspaceStore!
    private let corrupt = Data(#"{"collections": [ { "name": "Önemli" "#.utf8)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dev2kit-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv(AppPaths.directoryEnvironmentKey, directory.path, 1)
        store = WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        try corrupt.write(to: store.fileURL)
    }

    override func tearDownWithError() throws {
        unsetenv(AppPaths.directoryEnvironmentKey)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("workspace.bozuk-") }
    }

    func testUnreadableWorkspaceIsBackedUpBeforeBeingOverwritten() throws {
        let state = AppState(store: store, secretStore: FileSecretStore())
        state.waitForPendingWrites()

        let backup = try XCTUnwrap(try backups().first, "bozuk dosyanın yedeği alınmalıydı")
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        let message = try XCTUnwrap(state.startupMessage)
        XCTAssertEqual(message.kind, .warning, "veri kaybolmadı; hata değil uyarı")
        XCTAssertTrue(
            message.plainText.contains(backup.lastPathComponent),
            "uyarı yedeğin yerini söylemeli: \(message.plainText)"
        )
        XCTAssertEqual(message.revealURL?.lastPathComponent, backup.lastPathComponent)
        // Hemen ardından gelen başarılı kayıt uyarıyı silmemeli.
        let saved = expectation(description: "ilk kayıt bitti")
        DispatchQueue.main.async { saved.fulfill() }
        wait(for: [saved], timeout: 2)
        XCTAssertNotNil(state.startupMessage)
        // Uygulama boş workspace ile açılır ve normal şekilde kaydeder.
        XCTAssertNoThrow(try store.load())
        XCTAssertFalse(state.persistenceBlocked)
    }

    func testWhenBackupFailsNothingIsWritten() throws {
        // Okuma izni yok: hem okuma hem yedek başarısız. Dosyanın üzerine
        // yazmak tek kopyayı yok ederdi; bu oturumda kayıt kapalı kalmalı.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        let state = AppState(store: store, secretStore: FileSecretStore())
        state.addRequestToCurrentCollection()
        state.waitForPendingWrites()

        XCTAssertTrue(state.persistenceBlocked)
        XCTAssertEqual(state.startupMessage?.kind, .error)
        XCTAssertTrue(state.startupMessage?.title.contains("kaydedilmeyecek") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt, "dosyanın üzerine yazılmamalıydı")
        XCTAssertTrue(try backups().isEmpty)
    }
}
