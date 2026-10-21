import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Şema 1 `workspace.json` ile açılış: veri kayıpsız gelir, kullanıcıya söylenir,
/// sonraki kayıtlar yeni yapıya yazılır.
@MainActor
final class AppStateStorageMigrationTests: XCTestCase {
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dev2kit-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv(AppPaths.directoryEnvironmentKey, directory.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv(AppPaths.directoryEnvironmentKey)
        try? FileManager.default.removeItem(at: directory)
    }

    func testLegacyWorkspaceOpensMigratedAndTellsTheUser() throws {
        let request = RequestModel(name: "Taşınan", url: "https://api.example.test/a")
        let legacy = WorkspaceModel(collections: [CollectionModel(name: "Eski", requests: [request])])
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("workspace.json"))

        let store = WorkspaceStore(directory: directory)
        let state = AppState(store: store, secretStore: InMemorySecretStore())
        XCTAssertEqual(state.workspace.collections.first?.requests.first?.id, request.id)
        XCTAssertEqual(state.startupMessage?.title, "Kayıt yapısı güncellendi")
        XCTAssertTrue(state.startupMessage?.plainText.contains("workspace.v1") == true)

        state.addRequestToCurrentCollection()
        state.waitForPendingWrites()
        let reopened = try WorkspaceStore(directory: directory).open()
        XCTAssertTrue(reopened.notices.isEmpty)
        XCTAssertEqual(reopened.workspace.collections.first?.requests.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("workspace.json").path))
    }
}
