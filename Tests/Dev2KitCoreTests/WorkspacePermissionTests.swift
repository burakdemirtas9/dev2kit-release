import XCTest
@testable import Dev2KitCore

/// Workspace dosyası düz metin kimlik bilgisi içerebilir: yalnızca kullanıcı
/// okuyabilmeli (güvenlik incelemesi, 2026-10-20: önceden 0644).
final class WorkspacePermissionTests: XCTestCase {
    private func permissions(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    func testWorkspaceFileAndDirectoryArePrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-perm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        try store.save(WorkspaceModel())
        XCTAssertEqual(try permissions(store.fileURL.path), 0o600)
        XCTAssertEqual(try permissions(directory.path), 0o700)
        // Yeniden yazımda da korunur (atomik yazım dosyayı yeniden oluşturur).
        try store.save(WorkspaceModel())
        XCTAssertEqual(try permissions(store.fileURL.path), 0o600)
    }
}
