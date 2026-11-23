import XCTest
@testable import Dev2KitCore

/// Kenar çubuğu özeti (2026-11-01): yalnızca kenar çubuğunun gösterdiği şey
/// değişince değişir; yazarken (header, gövde, URL…) aynı kalır.
final class SidebarSnapshotTests: XCTestCase {
    private func workspace() -> WorkspaceModel {
        var a = CollectionModel(name: "Kullanıcılar")
        a.requests = [RequestModel(name: "Liste"), RequestModel(name: "Detay")]
        var b = CollectionModel(name: "Siparişler")
        b.requests = [RequestModel(name: "Oluştur")]
        return WorkspaceModel(collections: [a, b])
    }

    func testEditingContentKeepsTheSnapshot() {
        var ws = workspace()
        let before = SidebarSnapshot(workspace: ws)
        ws.collections[0].requests[0].headers = [KeyValueEntry(key: "Authorization", value: "Bearer x")]
        ws.collections[0].requests[0].body = .raw(content: "{\"a\":1}", contentType: "application/json")
        ws.collections[0].requests[0].url = "https://api.test/users"
        ws.collections[0].requests[0].queryParams = [KeyValueEntry(key: "q", value: "1")]
        XCTAssertEqual(SidebarSnapshot(workspace: ws), before, "yazarken kenar çubuğu yeniden çizilmez")
    }

    func testWhatTheSidebarShowsChangesTheSnapshot() {
        let base = workspace()
        let before = SidebarSnapshot(workspace: base)
        var renamed = base; renamed.collections[0].requests[0].name = "Tüm liste"
        var method = base; method.collections[0].requests[0].method = .post
        var reordered = base; reordered.collections[0].requests.swapAt(0, 1)
        var added = base; added.collections[1].requests.append(RequestModel(name: "Yeni"))
        var collection = base; collection.collections[1].name = "Sepet"
        var example = base
        example.collections[0].requests[0].examples = [ResponseExample(name: "200", statusCode: 200)]
        for changed in [renamed, method, reordered, added, collection, example] {
            XCTAssertNotEqual(SidebarSnapshot(workspace: changed), before)
        }
    }

    func testDirtyFlagFollowsTheSentBaseline() {
        var ws = workspace()
        let request = ws.collections[0].requests[0]
        ws.sentBaselines[request.id.uuidString] = request
        XCTAssertEqual(SidebarSnapshot(workspace: ws).dirty, [])
        ws.collections[0].requests[0].url = "https://changed.test"
        let dirty = SidebarSnapshot(workspace: ws)
        XCTAssertEqual(dirty.dirty, [request.id], "işaret değişince özet değişir")
        ws.collections[0].requests[0].url = "https://changed.test/more"
        XCTAssertEqual(SidebarSnapshot(workspace: ws), dirty, "kirli kalmaya devam: özet aynı")
    }

    func testMatchingKeepsSearchOrderAndTotals() {
        let ws = workspace()
        let snapshot = SidebarSnapshot(workspace: ws)
        let shown = snapshot.matching(RequestSearch.filter(ws.collections, query: "detay"))
        XCTAssertEqual(shown.map(\.name), ["Kullanıcılar"])
        XCTAssertEqual(shown.first?.requests.map(\.name), ["Detay"])
        XCTAssertEqual(shown.first?.totalRequests, 2, "başlıktaki sayı aramadan bağımsız")
        XCTAssertEqual(snapshot.matching(RequestSearch.filter(ws.collections, query: "")).map(\.requests.count), [2, 1])
        XCTAssertEqual(snapshot.requestName(ws.collections[1].requests[0].id), "Oluştur")
    }

    func testTreeRowsWorkTheSameForSnapshotRequests() {
        var ws = workspace()
        let owner = ws.collections[0].requests[0]
        ws.collections[0].requests[0].examples = [
            ResponseExample(name: "ok", statusCode: 200),
        ]
        let full = ws.collections[0].requests
        let summary = SidebarSnapshot(workspace: ws).collections[0].requests
        XCTAssertEqual(RequestTreeRows.rows(for: summary, expanded: [owner.id]), RequestTreeRows.rows(for: full, expanded: [owner.id]))
        XCTAssertEqual(RequestTreeRows.exampleOwners(in: summary), RequestTreeRows.exampleOwners(in: full))
    }

    /// Sürüklenen istek nereye bırakılabilir (2026-11-15): kendi collection'ları
    /// ve düzenlenebilen kurum collection'ı evet; salt okunur, içeriği çekilmemiş
    /// ya da eksik okunmuş kurum collection'ı ve Token Factory hayır.
    func testRequestDropTargets() {
        let own = CollectionModel(name: "Benim")
        let factory = CollectionModel(name: "Token Factory", isTokenFactory: true)
        let editable = CollectionModel(name: "Kurum yazılabilir")
        let readOnly = CollectionModel(name: "Kurum salt okunur")
        let unloaded = CollectionModel(name: "Kurum çekilmemiş")
        let partial = CollectionModel(name: "Kurum eksik")
        func summary(_ id: String, canUpdate: Bool) -> TeamCollectionSummary {
            TeamCollectionSummary(id: id, name: id, ownerGroup: "gf-cards", version: 1, canUpdate: canUpdate, canDelete: false)
        }
        let catalog = TeamCatalog(entries: [
            editable.id: TeamCollectionInfo(summary: summary("e", canUpdate: true), isLoaded: true),
            readOnly.id: TeamCollectionInfo(summary: summary("r", canUpdate: false), isLoaded: true),
            unloaded.id: TeamCollectionInfo(summary: summary("u", canUpdate: true), isLoaded: false),
            partial.id: TeamCollectionInfo(summary: summary("p", canUpdate: true), isLoaded: true, skippedRequests: 1),
        ])
        let snapshot = SidebarSnapshot(workspace: WorkspaceModel(collections: [own, factory, editable, readOnly, unloaded, partial]),
                                       team: catalog)
        let accepts = Dictionary(uniqueKeysWithValues: snapshot.collections.map { ($0.name, $0.acceptsRequestDrop) })
        XCTAssertEqual(accepts, [
            "Benim": true, "Token Factory": false, "Kurum yazılabilir": true,
            "Kurum salt okunur": false, "Kurum çekilmemiş": false, "Kurum eksik": false,
        ])

        // Kurum collection'ına giren ve düzenlenemeyenden çıkan kopyalanır.
        let other = CollectionModel(name: "Benim 2")
        XCTAssertFalse(catalog.dropCopies(from: [own.id], to: other.id), "yerelden yerele taşıma")
        XCTAssertTrue(catalog.dropCopies(from: [own.id], to: editable.id), "yerelden kuruma kopya")
        XCTAssertFalse(catalog.dropCopies(from: [editable.id], to: own.id), "düzenlenebilen kurumdan yerele taşıma")
        XCTAssertTrue(catalog.dropCopies(from: [readOnly.id], to: own.id), "salt okunurdan çıkarılamaz: kopya")
        XCTAssertTrue(catalog.dropCopies(from: [own.id, readOnly.id], to: other.id), "karışık seçimde biri salt okunursa kopya")
    }

    /// Başlıktaki "Sunucuya kaydet": kaydedilmemiş ve düzenlenebilenler, sırayla.
    func testSavableTeamCollections() {
        let a = UUID(), b = UUID(), lost = UUID(), clean = UUID(), local = UUID()
        func info(_ id: String, canUpdate: Bool = true, dirty: Bool) -> TeamCollectionInfo {
            TeamCollectionInfo(summary: TeamCollectionSummary(id: id, name: id, ownerGroup: "g", version: 1, canUpdate: canUpdate, canDelete: false),
                               isLoaded: true, isDirty: dirty)
        }
        let catalog = TeamCatalog(entries: [
            a: info("a", dirty: true), b: info("b", dirty: true),
            lost: info("l", canUpdate: false, dirty: true), clean: info("c", dirty: false),
        ])
        XCTAssertEqual(catalog.savableIDs(in: [b, local, lost, clean, a]), [b, a],
                       "sıra kenar çubuğundan; yetkisi düşen ve temiz olan atlanır")
        XCTAssertTrue(TeamCatalog().savableIDs(in: [local]).isEmpty)
    }
}
