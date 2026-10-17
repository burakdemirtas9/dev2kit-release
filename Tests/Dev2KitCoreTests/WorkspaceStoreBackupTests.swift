import XCTest
@testable import Dev2KitCore

/// Okunamayan workspace dosyası ezilmeden önce yedeklenir.
final class WorkspaceStoreBackupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dev2kit-backup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var date: Date {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 10, 17)
        (components.hour, components.minute, components.second) = (22, 45, 12)
        return Calendar.current.date(from: components)!
    }

    func testUnreadableFileIsCopiedNextToItWithItsContent() throws {
        let store = WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        try Data("{ bozuk".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())

        let backup = try store.backUpUnreadableFile(now: date)
        XCTAssertEqual(backup.lastPathComponent, "workspace.bozuk-20261017-224512.json")
        XCTAssertEqual(try Data(contentsOf: backup), Data("{ bozuk".utf8))
        // Kopya: yedek alınamasaydı asıl dosya yerinde kalmalıydı.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testBackupsInTheSameSecondDoNotOverwriteEachOther() throws {
        let store = WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        try Data("ilk".utf8).write(to: store.fileURL)
        let first = try store.backUpUnreadableFile(now: date)
        try Data("ikinci".utf8).write(to: store.fileURL)
        let second = try store.backUpUnreadableFile(now: date)

        XCTAssertEqual(second.lastPathComponent, "workspace.bozuk-20261017-224512-2.json")
        XCTAssertEqual(try String(contentsOf: first), "ilk")
        XCTAssertEqual(try String(contentsOf: second), "ikinci")
    }
}
