import XCTest
@testable import Dev2KitCore

/// Şema 3: response örnekleri istek başına ayrı dosyada; değişmeyen dosya
/// yeniden encode edilmez. Eski (şema 2, örnekler koleksiyonun içinde)
/// workspace'ler kayıpsız açılır.
final class WorkspaceStoreExampleTests: XCTestCase {
    private var directory: URL!
    private var store: WorkspaceStore!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent("dev2kit-examples-\(UUID().uuidString)")
        store = WorkspaceStore(directory: directory)
        _ = try store.open()
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: directory)
    }

    private func path(_ relative: String) -> URL { store.layout.store.appendingPathComponent(relative) }

    private func inode(_ url: URL) throws -> Int {
        try XCTUnwrap(manager.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    private func sample() -> WorkspaceModel {
        var withExamples = RequestModel(name: "örnekli", url: "https://api.example.test/a")
        withExamples.examples = [
            ResponseExample(name: "200 OK", statusCode: 200, headers: [.init(name: "Content-Type", value: "application/json")],
                            body: #"{"id": 1}"#, contentType: "application/json"),
            ResponseExample(name: "Boş", statusCode: 204),
        ]
        let plain = RequestModel(name: "örneksiz", url: "https://api.example.test/b")
        return WorkspaceModel(collections: [
            CollectionModel(name: "A", requests: [withExamples, plain]),
            CollectionModel(name: "B", requests: [RequestModel(name: "diğer")]),
        ])
    }

    func testExamplesAreStoredSeparatelyAndRoundTrip() throws {
        let model = sample()
        try store.save(model)
        let request = model.collections[0].requests[0]
        let collectionJSON = try String(contentsOf: path(StoreLayout.collectionPath(model.collections[0].id)), encoding: .utf8)
        XCTAssertFalse(collectionJSON.contains("\"examples\""), "koleksiyon dosyası örneksiz")
        XCTAssertTrue(manager.fileExists(atPath: path(StoreLayout.examplesPath(request.id)).path))
        XCTAssertFalse(manager.fileExists(atPath: path(StoreLayout.examplesPath(model.collections[0].requests[1].id)).path),
                       "örneği olmayan isteğe dosya açılmaz")
        let reopened = try WorkspaceStore(directory: directory).load()
        XCTAssertEqual(reopened.collections[0].requests[0].examples, request.examples)
        XCTAssertNil(WorkspaceStore.difference(model, reopened))
    }

    /// İstek düzenlemek örnek dosyasını yeniden yazmaz; örnek değişince
    /// yalnızca o dosya ve manifest yazılır.
    func testEditingRequestDoesNotRewriteItsExamples() throws {
        var model = sample()
        try store.save(model)
        let examplesFile = path(StoreLayout.examplesPath(model.collections[0].requests[0].id))
        let examplesInode = try inode(examplesFile)
        let collectionFile = path(StoreLayout.collectionPath(model.collections[0].id))
        let collectionInode = try inode(collectionFile)

        model.collections[0].requests[0].name = "yeni ad"
        try store.save(model)
        XCTAssertEqual(try inode(examplesFile), examplesInode, "örnek dosyası yeniden yazılmamalı")
        XCTAssertNotEqual(try inode(collectionFile), collectionInode)

        let afterRename = try inode(collectionFile)
        model.collections[0].requests[0].examples[0].name = "yeniden adlandırıldı"
        try store.save(model)
        XCTAssertNotEqual(try inode(examplesFile), examplesInode)
        XCTAssertEqual(try inode(collectionFile), afterRename, "örnek değişince koleksiyon dosyası yazılmaz")
        XCTAssertEqual(try WorkspaceStore(directory: directory).load().collections[0].requests[0].examples[0].name, "yeniden adlandırıldı")
    }

    func testDeletingRequestOrAllExamplesRemovesTheFile() throws {
        var model = sample()
        try store.save(model)
        let id = model.collections[0].requests[0].id
        model.collections[0].requests[0].examples = []
        try store.save(model)
        XCTAssertFalse(manager.fileExists(atPath: path(StoreLayout.examplesPath(id)).path))

        model = sample()
        try store.save(model)
        let removedID = model.collections[0].requests[0].id
        model.collections[0].requests.remove(at: 0)
        try store.save(model)
        XCTAssertFalse(manager.fileExists(atPath: path(StoreLayout.examplesPath(removedID)).path), "istek silinince örnek dosyası da")
    }

    /// Bugünkü önceki sürüm (şema 2) örnekleri koleksiyon dosyasının İÇİNE
    /// yazıyordu: kayıpsız açılır, ilk kayıtta ayrılır.
    func testSchema2WorkspaceWithInlineExamplesOpensAndIsSplitOnSave() throws {
        let model = sample()
        let encoder = WorkspaceStore.encoder
        var files: [String: Data] = [:]
        for collection in model.collections {
            files[StoreLayout.collectionPath(collection.id)] = try encoder.encode(collection)   // örnekler içinde
        }
        files[StoreLayout.environmentsPath] = try encoder.encode(model.environments)
        files[StoreLayout.settingsPath] = try encoder.encode(StoreSettings(tlsProfiles: [], sentBaselines: [:]))
        for (relative, data) in files {
            try manager.createDirectory(at: path(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path(relative))
        }
        let manifest = StoreManifest(schemaVersion: 2, activeEnvironmentID: nil,
                                     collectionOrder: model.collections.map(\.id), files: files.mapValues(AtomicFile.digest))
        try encoder.encode(manifest).write(to: store.layout.manifest)

        let legacyStore = WorkspaceStore(directory: directory)
        let opened = try legacyStore.open()
        XCTAssertTrue(opened.notices.isEmpty, "\(opened.notices)")
        XCTAssertEqual(opened.workspace.collections[0].requests[0].examples, model.collections[0].requests[0].examples)

        try legacyStore.save(opened.workspace)
        let collectionJSON = try String(contentsOf: path(StoreLayout.collectionPath(model.collections[0].id)), encoding: .utf8)
        XCTAssertFalse(collectionJSON.contains("\"examples\""))
        let savedManifest = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: store.layout.manifest))
        XCTAssertEqual(savedManifest.schemaVersion, 3)
        XCTAssertEqual(try WorkspaceStore(directory: directory).load().collections[0].requests[0].examples,
                       model.collections[0].requests[0].examples)
    }

    func testCorruptExampleFileIsQuarantinedAndBackupRestored() throws {
        let model = sample()
        try store.save(model)
        _ = try WorkspaceStore(directory: directory).open()   // doğrulanmış yedek
        let relative = StoreLayout.examplesPath(model.collections[0].requests[0].id)
        try Data("{ bozuk".utf8).write(to: path(relative))

        let opened = try WorkspaceStore(directory: directory).open()
        guard case .restoredFromBackup(_, let quarantine) = try XCTUnwrap(opened.notices.first) else {
            return XCTFail("yedekten dönüş bekleniyordu: \(opened.notices)")
        }
        XCTAssertTrue(manager.fileExists(atPath: quarantine.appendingPathComponent(relative).path), "bozuk dosya karantinada")
        XCTAssertEqual(opened.workspace.collections[0].requests[0].examples, model.collections[0].requests[0].examples)
    }

    /// Önbellekten gelen (bu turda encode edilmeyen) dosya diskte yoksa o an
    /// encode edilip yazılır: önbellek eksik dosya bırakmaz.
    func testCachedFilesAreWrittenWhenDiskStateIsGone() throws {
        let model = sample()
        try store.save(model)
        try manager.removeItem(at: store.layout.store)
        _ = try store.open()   // aynı örnek: önbellek dolu, diskte hiçbir şey yok
        try store.save(model)
        XCTAssertNil(WorkspaceStore.difference(model, try WorkspaceStore(directory: directory).load()))
    }

    func testExamplePathsAreValidatedLikeOtherPaths() {
        XCTAssertTrue(StoreLayout.isValidRelativePath(StoreLayout.examplesPath(UUID())))
        for bad in ["examples/../x.json", "examples/abc.json", "examples/\(UUID().uuidString).json/../../y", "examples/"] {
            XCTAssertFalse(StoreLayout.isValidRelativePath(bad), bad)
        }
    }
}
