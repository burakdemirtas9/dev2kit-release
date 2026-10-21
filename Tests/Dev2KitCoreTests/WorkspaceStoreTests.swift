import XCTest
@testable import Dev2KitCore

/// Dosya tabanlı depo (şema 2): ayrık dosyalar, günlük, yedek, kurtarma, geçiş.
/// Veriler sentetik; her test geçici dizinde.
final class WorkspaceStoreTests: XCTestCase {
    private var directory: URL!
    private var store: WorkspaceStore!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent("dev2kit-store-\(UUID().uuidString)")
        store = WorkspaceStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: directory)
    }

    private func sample(collections: Int = 3, requestsEach: Int = 2) -> WorkspaceModel {
        let environment = EnvironmentModel(name: "Dev", variables: [KeyValueEntry(key: "base", value: "https://api.example.test")])
        var model = WorkspaceModel(
            collections: (0..<collections).map { index in
                CollectionModel(name: "Koleksiyon \(index)", requests: (0..<requestsEach).map { RequestModel(name: "İstek \(index)-\($0)") })
            },
            environments: [environment],
            activeEnvironmentID: environment.id
        )
        model.sentBaselines = [model.collections[0].requests[0].id.uuidString: model.collections[0].requests[0]]
        model.tlsProfiles = [TLSProfile(hostPatterns: ["*.example.test"])]
        return model
    }

    private func path(_ relative: String) -> URL { store.layout.store.appendingPathComponent(relative) }

    private func inode(_ url: URL) throws -> Int {
        try XCTUnwrap(manager.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    private func assertSame(_ a: WorkspaceModel, _ b: WorkspaceModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(WorkspaceStore.difference(a, b), file: file, line: line)
    }

    // MARK: - Temel

    func testFreshStartIsEmptyAndSaveRoundTrips() throws {
        let opened = try store.open()
        XCTAssertTrue(opened.workspace.collections.isEmpty)
        XCTAssertTrue(opened.notices.isEmpty)
        let model = sample()
        try store.save(model)
        assertSame(model, try WorkspaceStore(directory: directory).load())
    }

    /// Tek isteği düzenlemek yalnızca kendi koleksiyon dosyasını ve manifest'i yazar.
    func testSmallChangeRewritesOnlyItsCollection() throws {
        var model = sample()
        try store.save(model)
        let untouched = [StoreLayout.collectionPath(model.collections[0].id),
                         StoreLayout.collectionPath(model.collections[2].id),
                         StoreLayout.environmentsPath, StoreLayout.settingsPath]
        let before = try untouched.map { try inode(path($0)) }
        let changed = path(StoreLayout.collectionPath(model.collections[1].id))
        let changedBefore = try inode(changed)

        model.collections[1].requests[0].url = "https://api.example.test/yeni"
        try store.save(model)

        XCTAssertEqual(try untouched.map { try inode(path($0)) }, before, "dokunulmayan dosyalar yeniden yazılmamalı")
        XCTAssertNotEqual(try inode(changed), changedBefore)
        assertSame(model, try WorkspaceStore(directory: directory).load())
    }

    func testUnchangedSnapshotWritesNothing() throws {
        let model = sample()
        try store.save(model)
        let manifestInode = try inode(store.layout.manifest)
        try store.save(model)
        XCTAssertEqual(try inode(store.layout.manifest), manifestInode)
    }

    func testDeletedCollectionFileIsRemovedAndOrderKept() throws {
        var model = sample()
        try store.save(model)
        let removed = model.collections.remove(at: 1)
        model.collections.reverse()
        try store.save(model)
        XCTAssertFalse(manager.fileExists(atPath: path(StoreLayout.collectionPath(removed.id)).path))
        XCTAssertEqual(try WorkspaceStore(directory: directory).load().collections.map(\.id), model.collections.map(\.id))
    }

    // MARK: - Eşzamanlı ve yarıda kalan kayıt

    func testConcurrentSavesLeaveAConsistentStore() throws {
        let base = sample()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            var model = base
            model.collections[index % 3].name = "eşzamanlı \(index)"
            try? store.save(model)
        }
        let reopened = try WorkspaceStore(directory: directory).open()
        XCTAssertTrue(reopened.notices.isEmpty, "özetler tutmalı, kurtarma gerekmemeli: \(reopened.notices)")
        XCTAssertEqual(reopened.workspace.collections.count, 3)
        XCTAssertFalse(manager.fileExists(atPath: store.layout.journal.path))
    }

    /// Günlük (commit) yazıldı, dosyalar taşınmadan kesildi: açılışta ileri tamamlanır.
    func testSaveInterruptedAfterCommitIsCompletedOnOpen() throws {
        let first = sample()
        try store.save(first)
        var second = first
        second.collections[0].name = "Kesilen kayıttan sonra"
        second.collections.append(CollectionModel(name: "Yeni"))
        try writeUncommittedTransaction(second, commit: true, applyFirst: 1)

        let opened = try WorkspaceStore(directory: directory).open()
        XCTAssertEqual(opened.notices, [.recoveredInterruptedSave])
        assertSame(second, opened.workspace)
        XCTAssertFalse(manager.fileExists(atPath: store.layout.journal.path))
        XCTAssertFalse(manager.fileExists(atPath: store.layout.staging.path))
    }

    /// Dosyalar staging'e yazıldı ama günlük yazılmadan kesildi: eski hal geçerli.
    func testSaveInterruptedBeforeCommitKeepsPreviousState() throws {
        let first = sample()
        try store.save(first)
        var second = first
        second.collections[0].name = "Hiç commit edilmedi"
        try writeUncommittedTransaction(second, commit: false, applyFirst: 0)

        let opened = try WorkspaceStore(directory: directory).open()
        XCTAssertTrue(opened.notices.isEmpty)
        assertSame(first, opened.workspace)
        XCTAssertFalse(manager.fileExists(atPath: store.layout.staging.path), "commit edilmemiş artık silinir")
    }

    /// Disk dolu benzeri: staging yazılamıyor. Kayıt hata verir, diskteki hal değişmez;
    /// engel kalkınca sonraki kayıt değişikliği yazar.
    func testFailedWriteKeepsPreviousStateAndRetriesLater() throws {
        let first = sample()
        try store.save(first)
        XCTAssertFalse(manager.fileExists(atPath: store.layout.staging.path), "işlem bitince staging kalmaz")
        try Data("engel".utf8).write(to: store.layout.staging) // dizin yerine dosya: oluşturulamaz
        var second = first
        second.collections[2].name = "Yazılamadı"
        XCTAssertThrowsError(try store.save(second))
        try manager.removeItem(at: store.layout.staging)
        assertSame(first, try WorkspaceStore(directory: directory).load())

        try store.save(second)
        assertSame(second, try WorkspaceStore(directory: directory).load())
    }

    private func writeUncommittedTransaction(_ model: WorkspaceModel, commit: Bool, applyFirst: Int) throws {
        let files = try WorkspaceStore.encode(model)
        let manifest = StoreManifest(schemaVersion: StoreManifest.currentSchema, activeEnvironmentID: model.activeEnvironmentID,
                                     collectionOrder: model.collections.map(\.id), files: files.mapValues(AtomicFile.digest))
        let id = UUID()
        let staging = store.layout.staging.appendingPathComponent(id.uuidString)
        let committedFiles = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: store.layout.manifest)).files
        let changed = files.filter { committedFiles[$0.key] != manifest.files[$0.key] }
        for (relative, data) in changed { try AtomicFile.write(data, to: staging.appendingPathComponent(relative)) }
        guard commit else { return }
        let journal = StoreJournal(id: id, writes: changed.keys.sorted(), deletes: [], manifest: manifest)
        try AtomicFile.write(try JSONEncoder().encode(journal), to: store.layout.journal)
        // Kesinti taşıma ortasında: ilk birkaç dosya yerinde, gerisi staging'de.
        for relative in journal.writes.prefix(applyFirst) {
            try manager.createDirectory(at: path(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: path(relative))
            try manager.moveItem(at: staging.appendingPathComponent(relative), to: path(relative))
        }
    }

    // MARK: - Bozuk / eksik dosya

    func testCorruptCollectionRestoresLastGoodBackupAndKeepsTheBadFile() throws {
        let model = sample()
        try store.save(model)
        _ = try WorkspaceStore(directory: directory).open() // açılışta doğrulanmış yedek
        let target = path(StoreLayout.collectionPath(model.collections[1].id))
        let garbage = Data("{ bozuk".utf8)
        try garbage.write(to: target)

        let opened = try WorkspaceStore(directory: directory).open()
        assertSame(model, opened.workspace)
        guard case .restoredFromBackup(_, let quarantine) = try XCTUnwrap(opened.notices.first) else {
            return XCTFail("yedekten dönüş bekleniyordu: \(opened.notices)")
        }
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent(StoreLayout.collectionPath(model.collections[1].id))), garbage,
                       "bozuk dosya silinmez, karantinada")
        XCTAssertTrue(try WorkspaceStore(directory: directory).open().notices.isEmpty, "geri yüklenen hal sağlam")
    }

    func testCorruptWithoutBackupLoadsReadablePartAndReportsLoss() throws {
        let model = sample()
        try store.save(model)
        try? manager.removeItem(at: store.layout.backups)
        let lostPath = StoreLayout.collectionPath(model.collections[0].id)
        try Data("bozuk".utf8).write(to: path(lostPath))

        let opened = try WorkspaceStore(directory: directory).open()
        XCTAssertEqual(opened.workspace.collections.map(\.id), model.collections.dropFirst().map(\.id))
        XCTAssertEqual(opened.workspace.environments.map(\.id), model.environments.map(\.id))
        guard case .partiallyLoaded(let lost, let quarantine) = try XCTUnwrap(opened.notices.first) else {
            return XCTFail("kısmi yükleme bekleniyordu: \(opened.notices)")
        }
        XCTAssertEqual(lost, [lostPath])
        XCTAssertTrue(manager.fileExists(atPath: quarantine.appendingPathComponent(lostPath).path))
        XCTAssertTrue(try WorkspaceStore(directory: directory).open().notices.isEmpty, "yapı tutarlı yeniden yazıldı")
    }

    func testMissingFileIsDetectedNotTreatedAsEmpty() throws {
        let model = sample()
        try store.save(model)
        _ = try WorkspaceStore(directory: directory).open()
        try manager.removeItem(at: path(StoreLayout.environmentsPath))
        let opened = try WorkspaceStore(directory: directory).open()
        XCTAssertEqual(opened.workspace.environments.map(\.id), model.environments.map(\.id), "yedekten döndü")
        XCTAssertFalse(opened.notices.isEmpty)
    }

    func testMissingManifestRecoversFromBackup() throws {
        let model = sample()
        try store.save(model)
        _ = try WorkspaceStore(directory: directory).open()
        try manager.removeItem(at: store.layout.manifest)
        assertSame(model, try WorkspaceStore(directory: directory).load())
    }

    func testNewerSchemaIsNeverOverwritten() throws {
        try store.save(sample())
        var manifest = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: store.layout.manifest))
        manifest.schemaVersion = StoreManifest.currentSchema + 1
        let bytes = try JSONEncoder().encode(manifest)
        try bytes.write(to: store.layout.manifest)
        XCTAssertThrowsError(try WorkspaceStore(directory: directory).open()) { error in
            XCTAssertEqual(error as? StoreError, .newerSchema(found: StoreManifest.currentSchema + 1, supported: StoreManifest.currentSchema))
        }
        XCTAssertEqual(try Data(contentsOf: store.layout.manifest), bytes)
    }

    // MARK: - Yedek

    func testBackupsAreTakenOnOpenAndRotated() throws {
        try store.save(sample())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for hour in 0..<8 {
            let date = start.addingTimeInterval(Double(hour) * 3_600)
            _ = try WorkspaceStore(directory: directory, clock: { date }).open()
        }
        let backups = store.backupsNewestFirst()
        XCTAssertEqual(backups.count, WorkspaceStore.keptBackups)
        XCTAssertEqual(backups.first?.lastPathComponent, WorkspaceStore.stamp(start.addingTimeInterval(7 * 3_600)))
        for backup in backups { guard case .success = WorkspaceStore.read(backup) else { return XCTFail("yedek okunamıyor") } }
    }

    // MARK: - Şema 1'den geçiş

    private func writeLegacy(_ model: WorkspaceModel) throws -> Data {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // şema 1 böyle yazıyordu
        let data = try encoder.encode(model)
        try data.write(to: store.layout.legacyWorkspace)
        return data
    }

    func testLegacyWorkspaceMigratesLosslesslyWithBackup() throws {
        let model = sample(collections: 4, requestsEach: 5)
        let original = try writeLegacy(model)

        let opened = try store.open()
        assertSame(model, opened.workspace)
        guard case .migrated(let backup) = try XCTUnwrap(opened.notices.first) else { return XCTFail("\(opened.notices)") }
        XCTAssertEqual(try Data(contentsOf: backup), original, "asıl dosyanın birebir yedeği")
        XCTAssertFalse(manager.fileExists(atPath: store.layout.legacyWorkspace.path))
        XCTAssertFalse(manager.fileExists(atPath: store.layout.migrating.path))
        assertSame(model, try WorkspaceStore(directory: directory).load())
    }

    /// Yarıda kalmış geçiş (ara dizin kalmış) yeniden denenir; kayıt çoğalmaz.
    func testInterruptedMigrationIsRetriedWithoutDuplicates() throws {
        let model = sample()
        _ = try writeLegacy(model)
        try manager.createDirectory(at: store.layout.migrating.appendingPathComponent("collections"), withIntermediateDirectories: true)
        try Data("yarım".utf8).write(to: store.layout.migrating.appendingPathComponent("collections/\(UUID().uuidString).json"))

        let opened = try store.open()
        assertSame(model, opened.workspace)
        XCTAssertEqual(opened.workspace.collections.flatMap(\.requests).count, 6)

        // Asıl dosya geri gelse (ör. kullanıcı yedekten kopyaladı) bile ikinci geçiş olmaz.
        _ = try writeLegacy(model)
        let again = try WorkspaceStore(directory: directory).open()
        XCTAssertEqual(again.workspace.collections.count, 3)
        let legacyBackups = try manager.contentsOfDirectory(atPath: store.layout.backups.path).filter { $0.hasPrefix("workspace.v1") }
        XCTAssertEqual(legacyBackups.count, 1, "aynı içerikli yedek tekrar alınmaz")
        XCTAssertFalse(manager.fileExists(atPath: store.layout.legacyWorkspace.path))
    }

    func testUnreadableLegacyIsBackedUpAndNotOverwritten() throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data(#"{"collections": [ { "name": "Önemli" "#.utf8)
        try corrupt.write(to: store.layout.legacyWorkspace)
        let opened = try store.open()
        guard case .legacyUnreadable(let backup, _) = try XCTUnwrap(opened.notices.first) else { return XCTFail("\(opened.notices)") }
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        XCTAssertTrue(opened.workspace.collections.isEmpty)
    }
}
