import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kurum collection'larının uygulamadaki korumaları: salt okunur geri alma,
/// kaydedilmedi işareti, workspace kaydına girmeme, çıkışta temizlik.
@MainActor
final class AppStateTeamTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }

    override func setUp() async throws {
        harness = AppStateHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
        harness = nil
    }

    /// Servisten gelmiş gibi bir kurum collection'ı yerleştirir.
    @discardableResult
    private func installTeam(canUpdate: Bool, loaded: Bool = true) -> CollectionModel {
        let request = RequestModel(name: "Ödeme", method: .get, url: "https://api.example.com/pay")
        let collection = CollectionModel(id: UUID(), name: "Payments API", requests: [request])
        let summary = TeamCollectionSummary(id: "c-1", name: "Payments API", ownerGroup: "gf-payments", version: 3,
                                            canUpdate: canUpdate, canDelete: canUpdate)
        state.applyTeam { state in
            state.teamCatalog = TeamCatalog(entries: [collection.id: TeamCollectionInfo(summary: summary, isLoaded: loaded)])
            state.workspace.collections.insert(collection, at: 0)
        }
        return collection
    }

    func testReadOnlyEditIsReverted() {
        let team = installTeam(canUpdate: false)
        var edited = team.requests[0]
        edited.url = "https://evil.example.com"
        state.workspace.collections[0].requests[0] = edited

        XCTAssertEqual(state.workspace.collections[0].requests[0].url, "https://api.example.com/pay")
        XCTAssertNotNil(state.teamNotice)
        XCTAssertEqual(state.teamCatalog.entries[team.id]?.isDirty, false)
    }

    func testCachedButUnloadedIsReadOnlyEvenWithPermission() {
        let team = installTeam(canUpdate: true, loaded: false)
        state.workspace.collections[0].name = "Başka ad"
        XCTAssertEqual(state.workspace.collections[0].name, team.name)
    }

    func testEditableEditMarksDirty() {
        let team = installTeam(canUpdate: true)
        state.workspace.collections[0].requests[0].url = "https://api.example.com/v2/pay"

        XCTAssertEqual(state.workspace.collections[0].requests[0].url, "https://api.example.com/v2/pay")
        XCTAssertEqual(state.teamCatalog.entries[team.id]?.isDirty, true)
    }

    func testMovingOutOfReadOnlyCollectionIsUndone() throws {
        let team = installTeam(canUpdate: false)
        let own = try XCTUnwrap(state.workspace.collections.first { $0.id != team.id })
        state.moveRequests([team.requests[0].id], toCollection: own.id)

        let after = state.workspace.collections
        XCTAssertEqual(after.first { $0.id == team.id }?.requests.map(\.id), [team.requests[0].id])
        XCTAssertFalse(after.first { $0.id == own.id }?.requests.contains { $0.id == team.requests[0].id } ?? true)
    }

    func testReadOnlyCollectionCannotBeDeletedLocally() {
        let team = installTeam(canUpdate: false)
        state.deleteCollection(team.id)
        XCTAssertTrue(state.workspace.collections.contains { $0.id == team.id })
    }

    func testTeamCollectionsAreNotWrittenToWorkspace() throws {
        harness.addRequest(named: "Benim isteğim")
        let team = installTeam(canUpdate: true)
        state.workspace.collections[0].requests[0].url = "https://api.example.com/v2/pay"
        state.persist()

        let saved = try harness.savedWorkspace()
        XCTAssertFalse(saved.collections.contains { $0.id == team.id })
        XCTAssertTrue(saved.collections.flatMap(\.requests).contains { $0.name == "Benim isteğim" })
    }

    func testEndingSessionRemovesCollectionsAndCache() throws {
        let team = installTeam(canUpdate: false)
        let cache = TeamCache(identity: TeamIdentity(username: "alice", displayName: nil, group: "gf-payments"),
                              canCreate: true, catalog: state.teamCatalog, collections: [team])
        try cache.save(root: harness.store.layout.root)
        XCTAssertNotNil(TeamCache.load(root: harness.store.layout.root))

        state.endTeamSession(keepNotice: false)

        XCTAssertFalse(state.workspace.collections.contains { $0.id == team.id })
        XCTAssertTrue(state.teamCatalog.entries.isEmpty)
        XCTAssertNil(TeamCache.load(root: harness.store.layout.root))
        XCTAssertEqual(state.teamStatus, .loggedOut)
    }

    /// Kaydedilmemiş kurum düzenlemesi uygulama kapanınca kaybolmaz: önbelleğe
    /// yazılır, sonraki açılışta kaldığı yerden sürer (inceleme bulgu 1).
    func testUnsavedTeamEditSurvivesRestart() throws {
        let team = installTeam(canUpdate: true)
        state.teamStatus = .loggedIn(TeamIdentity(username: "alice", displayName: nil, group: "gf-payments"))
        state.saveTeamCache()

        // Editörde yazmak: istek bağlaması üzerinden, gecikmeli kayıtla.
        state.selectedRequestID = team.requests[0].id
        state.selectedRequest?.wrappedValue.url = "https://api.example.com/benim"
        XCTAssertTrue(state.teamCacheNeedsSave)
        state.waitForPendingWrites()   // kapanışta yapılan
        XCTAssertFalse(state.teamCacheNeedsSave)

        let cache = try XCTUnwrap(TeamCache.load(root: harness.store.layout.root))
        XCTAssertEqual(cache.collections.first?.requests.first?.url, "https://api.example.com/benim")
        XCTAssertEqual(cache.catalog.entries[team.id]?.isDirty, true)
        XCTAssertFalse(try harness.savedWorkspace().collections.contains { $0.id == team.id }, "workspace kaydına yine girmez")

        // Yeniden açılış: aynı veri dizini, yeni durum.
        let reopened = AppState(store: WorkspaceStore(directory: harness.directory), secretStore: FileSecretStore())
        XCTAssertEqual(reopened.workspace.collections.first { $0.id == team.id }?.requests.first?.url,
                       "https://api.example.com/benim")
        XCTAssertEqual(reopened.teamCatalog.dirtyIDs, [team.id], "hâlâ kaydedilmedi olarak görünür")
    }

    /// Kendi collection'ındaki düzenleme kurum önbelleğini yeniden yazdırmaz.
    func testOwnEditsDoNotRewriteTheTeamCache() throws {
        installTeam(canUpdate: true)
        let own = try XCTUnwrap(state.workspace.collections.first { !state.isTeamCollection($0.id) })
        state.addRequest(to: own.id)
        state.selectedRequest?.wrappedValue.url = "https://api.example.com/x"
        XCTAssertFalse(state.teamCacheNeedsSave)
    }

    /// Oturum biterken (süre doldu, çıkış) kaydedilmemiş çalışma atılmaz:
    /// kendi collection'larına kopyalanır, workspace'e yazılır ve söylenir.
    func testEndingSessionKeepsUnsavedWorkAsOwnCopy() throws {
        let team = installTeam(canUpdate: true)
        state.workspace.collections[0].requests[0].url = "https://api.example.com/benim"
        XCTAssertEqual(state.teamCatalog.dirtyIDs, [team.id])

        let rescued = state.endTeamSession(keepNotice: false)

        XCTAssertEqual(rescued.count, 1)
        XCTAssertFalse(state.workspace.collections.contains { $0.id == team.id }, "kurum collection'ı gider")
        let copy = try XCTUnwrap(state.workspace.collections.first { $0.name == rescued[0] })
        XCTAssertEqual(copy.requests.map(\.url), ["https://api.example.com/benim"])
        XCTAssertFalse(state.isTeamCollection(copy.id))
        XCTAssertTrue(state.teamNotice?.contains(rescued[0]) == true, "nereye gittiği söylenir")
        XCTAssertTrue(try harness.savedWorkspace().collections.contains { $0.id == copy.id }, "kopya kalıcı")
    }

    /// Kaydedilmiş (temiz) collection için kopya çıkmaz, not düşülmez.
    func testEndingSessionWithoutUnsavedWorkCopiesNothing() {
        installTeam(canUpdate: true)
        let before = state.workspace.collections.count - 1
        XCTAssertTrue(state.endTeamSession(keepNotice: false).isEmpty)
        XCTAssertEqual(state.workspace.collections.count, before)
        XCTAssertNil(state.teamNotice)
    }

    /// Sunucuda değişmiş + yerelde kaydedilmemiş: "Benimkini koru" çalışmayı
    /// olduğu gibi bırakır ve soruyu kapatır; çıkışta kuyruk temizlenir.
    func testKeepingMineOnRemoteChangeLeavesLocalWork() async {
        let team = installTeam(canUpdate: true)
        state.workspace.collections[0].requests[0].url = "https://api.example.com/benim"
        state.teamRemoteChangedIDs = [team.id]

        await state.teamResolveRemoteChange(team.id, loadServer: false)

        XCTAssertTrue(state.teamRemoteChangedIDs.isEmpty)
        XCTAssertEqual(state.workspace.collections[0].requests[0].url, "https://api.example.com/benim")
        XCTAssertEqual(state.teamCatalog.entries[team.id]?.isDirty, true)
        XCTAssertEqual(state.teamCatalog.entries[team.id]?.summary.version, 3, "dayandığı sürüm değişmez")

        state.teamRemoteChangedIDs = [team.id]
        state.endTeamSession(keepNotice: false)
        XCTAssertTrue(state.teamRemoteChangedIDs.isEmpty)
    }

    /// Düzenlenebilir kurum collection'ı yeniden adlandırılır (kaydedilmedi
    /// olur); sunucunun kabul etmeyeceği ad ve salt okunur collection reddedilir.
    func testRenamingTeamCollection() {
        let team = installTeam(canUpdate: true)
        state.renameCollection(team.id, to: "Payments API v2")
        XCTAssertEqual(state.workspace.collections[0].name, "Payments API v2")
        XCTAssertEqual(state.teamCatalog.entries[team.id]?.isDirty, true)

        state.renameCollection(team.id, to: "Ödemeler: v3")
        XCTAssertEqual(state.workspace.collections[0].name, "Payments API v2", "sunucunun kabul etmeyeceği ad (:) yerelde de reddedilir")
        XCTAssertEqual(state.teamNotice, TeamError.invalidName.localizedDescription)
    }

    func testRenamingReadOnlyTeamCollectionIsIgnored() {
        let team = installTeam(canUpdate: false)
        state.renameCollection(team.id, to: "Yeni ad")
        XCTAssertEqual(state.workspace.collections[0].name, team.name)
        XCTAssertNil(state.teamNotice)
    }

    func testCopyToMineIsEditableAndHasNewIDs() {
        let team = installTeam(canUpdate: false)
        state.teamCopyToMine(team.id)

        let copy = state.workspace.collections.last!
        XCTAssertFalse(state.isTeamCollection(copy.id))
        XCTAssertNotEqual(copy.requests[0].id, team.requests[0].id)
        XCTAssertEqual(copy.requests[0].url, team.requests[0].url)
        // Kopya serbestçe düzenlenir.
        let index = state.workspace.collections.count - 1
        state.workspace.collections[index].requests[0].url = "https://changed.example.com"
        XCTAssertEqual(state.workspace.collections[index].requests[0].url, "https://changed.example.com")
    }

    // MARK: Sürükle-bırak ile kurum collection'ına taşıma (2026-11-15)

    /// Kurum collection'ına bırakılan KOPYALANIR; yerel asıl yerinde kalır.
    func testDroppingALocalRequestOnAnEditableTeamCollectionCopiesIt() throws {
        let local = harness.addRequest(named: "Yerel istek")
        let team = installTeam(canUpdate: true)
        let source = try XCTUnwrap(state.workspace.collections.first { $0.requests.contains { $0.id == local.id } })
        state.collapsedCollectionIDs.insert(team.id)

        state.dropRequests([local.id], on: team.id)

        let target = try XCTUnwrap(state.workspace.collections.first { $0.id == team.id })
        XCTAssertEqual(target.requests.map(\.name), ["Ödeme", "Yerel istek"], "hedefin sonuna eklenir")
        let copy = try XCTUnwrap(target.requests.last)
        XCTAssertNotEqual(copy.id, local.id, "kopya yeni kimlikle")
        XCTAssertEqual(copy.url, local.url)
        XCTAssertEqual(state.workspace.collections.first { $0.id == source.id }?.requests.contains { $0.id == local.id }, true,
                       "yerel asıl yerinde kalır")
        XCTAssertEqual(state.teamCatalog.entries[team.id]?.isDirty, true, "sunucuya kaydedilene kadar kaydedilmedi")
        XCTAssertFalse(state.collapsedCollectionIDs.contains(team.id), "hedef açılır")
        XCTAssertEqual(state.selectedRequestID, copy.id, "kopya seçili")
    }

    func testDroppingOnAReadOnlyOrUnloadedTeamCollectionDoesNothing() throws {
        for loaded in [true, false] {
            harness.tearDown()
            harness = AppStateHarness()
            let local = harness.addRequest(named: "Yerel istek")
            let team = installTeam(canUpdate: !loaded, loaded: loaded)
            let before = state.workspace.collections

            state.dropRequests([local.id], on: team.id)

            XCTAssertEqual(state.workspace.collections, before)
            XCTAssertNil(state.teamNotice, "bırakma reddedildi; geri alma bildirimi gerekmez")
        }
    }

    func testDroppingOnAnotherLocalCollectionMovesIt() throws {
        let local = harness.addRequest(named: "Yerel istek")
        state.addCollection()
        let other = try XCTUnwrap(state.workspace.collections.last)

        state.dropRequests([local.id], on: other.id)

        let moved = try XCTUnwrap(state.workspace.collections.last?.requests.first)
        XCTAssertEqual(moved.id, local.id)
        XCTAssertEqual(state.workspace.collections.flatMap(\.requests).filter { $0.id == local.id }.count, 1, "kopya değil taşıma")
    }

    func testDroppingOnTheSameCollectionIsANoOp() throws {
        let local = harness.addRequest(named: "Yerel istek")
        let source = try XCTUnwrap(state.workspace.collections.first { $0.requests.contains { $0.id == local.id } })
        let before = state.workspace.collections
        state.dropRequests([local.id], on: source.id)
        XCTAssertEqual(state.workspace.collections, before, "aynı yere bırakmak adı değiştirmez")
    }
}
