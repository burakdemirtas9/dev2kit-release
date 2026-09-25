import XCTest
@testable import Dev2KitCore

/// Arka plan yazıcısının iki garantisi test edilir: yazım gerçekten diske
/// iner (kapanışta bekleyince) ve seri kuyruk sayesinde SON çağrı son yazımdır.
final class WorkspaceSaverTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dev2kit-saver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("workspace.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func workspace(collectionName: String) -> WorkspaceModel {
        var model = WorkspaceModel()
        model.collections = [CollectionModel(name: collectionName, requests: [RequestModel()])]
        return model
    }

    func testWaitForPendingWritesFlushesToDisk() throws {
        let saver = WorkspaceSaver(store: WorkspaceStore(fileURL: fileURL))
        saver.save(workspace(collectionName: "ilk"))
        saver.waitForPendingWrites()

        let saved = try WorkspaceStore(fileURL: fileURL).load()
        XCTAssertEqual(saved.collections.first?.name, "ilk")
    }

    func testLastWriteWins() throws {
        let saver = WorkspaceSaver(store: WorkspaceStore(fileURL: fileURL))
        for index in 1...20 {
            saver.save(workspace(collectionName: "yazim-\(index)"))
        }
        saver.waitForPendingWrites()

        let saved = try WorkspaceStore(fileURL: fileURL).load()
        XCTAssertEqual(saved.collections.first?.name, "yazim-20")
    }

    func testSaveDoesNotBlockCaller() {
        let saver = WorkspaceSaver(store: WorkspaceStore(fileURL: fileURL))
        let done = expectation(description: "yazim tamamlandi")
        saver.save(workspace(collectionName: "async")) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        // Tamamlanma main queue'ya gider; bu bekleme onu çalıştırır.
        wait(for: [done], timeout: 5)
    }
}
