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
        let store = WorkspaceStore(directory: directory)
        let collection = CollectionModel(name: "A")
        try store.save(WorkspaceModel(collections: [collection]))
        let collectionFile = store.layout.store.appendingPathComponent(StoreLayout.collectionPath(collection.id)).path
        for file in [store.layout.manifest.path, collectionFile] {
            XCTAssertEqual(try permissions(file), 0o600, file)
        }
        for folder in [directory.path, store.layout.store.path] {
            XCTAssertEqual(try permissions(folder), 0o700, folder)
        }
        // Yeniden yazımda da korunur (atomik yazım dosyayı yeniden oluşturur).
        try store.save(WorkspaceModel(collections: [CollectionModel(id: collection.id, name: "B")]))
        XCTAssertEqual(try permissions(collectionFile), 0o600)
    }
}
