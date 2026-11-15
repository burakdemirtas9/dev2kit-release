import XCTest
@testable import Dev2KitCore

/// Kurum collection'larının merkezi korunması ve listenin yerleşmesi.
final class TeamSyncTests: XCTestCase {
    private func summary(_ id: String, owner: String = "gf-payments", version: Int = 0, canUpdate: Bool = false) -> TeamCollectionSummary {
        TeamCollectionSummary(id: id, name: "C-\(id)", ownerGroup: owner, version: version, canUpdate: canUpdate, canDelete: canUpdate)
    }

    private func setup(canUpdate: Bool) -> (team: CollectionModel, mine: CollectionModel, catalog: TeamCatalog) {
        let request = RequestModel(name: "pay", method: .post, url: "/pay")
        let team = CollectionModel(id: TeamCollectionCodec.stableID("r1", "collection"), name: "T", requests: [request])
        let mine = CollectionModel(name: "Mine")
        let catalog = TeamCatalog(entries: [team.id: TeamCollectionInfo(summary: summary("r1", canUpdate: canUpdate), isLoaded: true)])
        return (team, mine, catalog)
    }

    func testReadOnlyEditIsReverted() {
        let (team, mine, catalog) = setup(canUpdate: false)
        var edited = team
        edited.requests[0].url = "/değişti"
        let result = TeamSync.enforce(old: [team, mine], new: [edited, mine], catalog: catalog)
        XCTAssertTrue(result.blocked)
        XCTAssertEqual(result.collections, [team, mine])
    }

    func testDraggingOutOfAReadOnlyCollectionDoesNotDuplicate() {
        let (team, mine, catalog) = setup(canUpdate: false)
        var emptied = team
        let moved = emptied.requests.removeFirst()
        var target = mine
        target.requests.append(moved)
        let result = TeamSync.enforce(old: [team, mine], new: [emptied, target], catalog: catalog)
        XCTAssertTrue(result.blocked)
        XCTAssertEqual(result.collections[0], team)
        XCTAssertTrue(result.collections[1].requests.isEmpty, "taşınan istek hedeften çıkarılır, kimlik çakışmaz")
    }

    /// İki adımlı taşıma: önce çıkarma (geri alınır), sonra hedefe ekleme.
    /// İkinci adımda kurum collection'ı değişmemiş görünür; yine de kopya kimlik girmez.
    func testAddingAReadOnlyRequestElsewhereInASeparateStepIsUndone() {
        let (team, mine, catalog) = setup(canUpdate: false)
        var target = mine
        target.requests.append(team.requests[0])
        let result = TeamSync.enforce(old: [team, mine], new: [team, target], catalog: catalog)
        XCTAssertTrue(result.blocked)
        XCTAssertTrue(result.collections[1].requests.isEmpty)
    }

    func testDeletingIsRevertedButCopyingIsAllowed() {
        let (team, mine, catalog) = setup(canUpdate: true)
        let deleted = TeamSync.enforce(old: [team, mine], new: [mine], catalog: catalog)
        XCTAssertTrue(deleted.blocked, "silme yalnızca sunucu üzerinden")
        XCTAssertEqual(deleted.collections.map(\.id), [team.id, mine.id])

        var copy = team.requests[0]
        copy.id = UUID()
        var target = mine
        target.requests.append(copy)
        let copied = TeamSync.enforce(old: [team, mine], new: [team, target], catalog: catalog)
        XCTAssertFalse(copied.blocked)
        XCTAssertEqual(copied.collections[1].requests.count, 1)
    }

    func testEditableChangeIsMarkedDirty() {
        let (team, mine, catalog) = setup(canUpdate: true)
        var edited = team
        edited.requests[0].url = "/yeni"
        let result = TeamSync.enforce(old: [team, mine], new: [edited, mine], catalog: catalog)
        XCTAssertFalse(result.blocked)
        XCTAssertEqual(result.dirtied, [team.id])
        XCTAssertEqual(result.collections[0], edited)
    }

    /// Atılacak kurum collection'larından yalnızca kaydedilmemiş olanlar kopyalanır:
    /// yeni kimlikler, çakışmayan ad, içerik aynı.
    func testRescueCopiesOnlyUnsavedWorkWithNewIDs() {
        let (team, mine, clean) = setup(canUpdate: true)
        XCTAssertTrue(TeamSync.rescueCopies(dropping: [team.id], from: [team, mine], catalog: clean, suffix: "kopya").isEmpty,
                      "kaydedilmiş collection kopyalanmaz")

        var dirty = clean
        dirty.entries[team.id]?.isDirty = true
        let taken = CollectionModel(name: "T kopya")
        let copies = TeamSync.rescueCopies(dropping: [team.id], from: [team, mine, taken], catalog: dirty, suffix: "kopya")
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies[0].name, "T kopya 2", "var olan adla çakışmaz")
        XCTAssertNotEqual(copies[0].id, team.id)
        XCTAssertNotEqual(copies[0].requests[0].id, team.requests[0].id, "kurum collection'ı geri gelince kimlik çakışmaz")
        XCTAssertEqual(copies[0].requests.map(\.url), team.requests.map(\.url))

        XCTAssertTrue(TeamSync.rescueCopies(dropping: [], from: [team, mine], catalog: dirty, suffix: "kopya").isEmpty,
                      "atılmayan collection kopyalanmaz")
        XCTAssertTrue(TeamSync.rescueCopies(dropping: [mine.id], from: [team, mine], catalog: dirty, suffix: "kopya").isEmpty,
                      "kendi collection'ı kurtarılacak bir şey değil")
    }

    func testOwnCollectionsAreUntouched() {
        let (team, mine, catalog) = setup(canUpdate: false)
        var renamed = mine
        renamed.name = "Benim"
        let result = TeamSync.enforce(old: [team, mine], new: [team, renamed], catalog: catalog)
        XCTAssertFalse(result.blocked)
        XCTAssertEqual(result.collections[1].name, "Benim")
    }

    func testMergeOrdersOwnTeamFirstAndTracksVersions() throws {
        let mine = CollectionModel(name: "Mine")
        var merged = TeamSync.merge([summary("b", owner: "gf-cards"), summary("a", owner: "gf-payments")],
                                    into: [mine], catalog: TeamCatalog(), ownGroup: "gf-payments")
        XCTAssertEqual(merged.collections.map(\.name), ["C-a", "C-b", "Mine"], "kendi ekibi önce, kendi collection'ları sonda")
        XCTAssertTrue(merged.catalog.entries.values.allSatisfy { !$0.isLoaded }, "liste içerik taşımaz")

        let detail = TeamCollectionDetail(summary: summary("a"), content: Data(#"{"requests":[{"name":"x","method":"GET"}]}"#.utf8))
        let applied = try TeamSync.apply(detail, to: merged.collections, catalog: merged.catalog)
        let id = TeamCollectionCodec.stableID("a", "collection")
        XCTAssertEqual(applied.catalog.entries[id]?.isLoaded, true)
        XCTAssertEqual(applied.collections.first { $0.id == id }?.requests.map(\.name), ["x"])

        merged = TeamSync.merge([summary("a", version: 0)], into: applied.collections, catalog: applied.catalog, ownGroup: "gf-payments")
        XCTAssertEqual(merged.catalog.entries[id]?.isLoaded, true, "sürüm aynı: içerik korunur")
        XCTAssertEqual(merged.collections.map(\.name), ["C-a", "Mine"], "sunucuda olmayan çıkar")
        merged = TeamSync.merge([summary("a", version: 1)], into: merged.collections, catalog: merged.catalog, ownGroup: "gf-payments")
        XCTAssertEqual(merged.catalog.entries[id]?.isLoaded, false, "sürüm değişti: yeniden çekilecek")
    }

    /// Kaydedilmemiş değişiklik varken sunucu değişti: yerel çalışma ezilmez,
    /// kullanıcıya sorulur ve yerel kayıt ESKİ sürümde kalır (kaydetme 409 alır,
    /// başkasının değişikliği sessizce ezilmez).
    func testDirtyCollectionKeepsBaseVersionWhenServerChanges() {
        let (team, mine, _) = setup(canUpdate: true)
        var edited = team
        edited.requests[0].url = "/benim-değişikliğim"
        let catalog = TeamCatalog(entries: [team.id: TeamCollectionInfo(summary: summary("r1", version: 2, canUpdate: true),
                                                                        isLoaded: true, isDirty: true)])
        let server = TeamCollectionSummary(id: "r1", name: "Sunucudaki ad", ownerGroup: "gf-payments", version: 3,
                                           updatedBy: "bob", canUpdate: true, canDelete: true)
        let merged = TeamSync.merge([server], into: [edited, mine], catalog: catalog, ownGroup: "gf-payments")

        XCTAssertEqual(merged.remoteChanged, [team.id])
        XCTAssertEqual(merged.collections[0], edited, "yerel çalışma olduğu gibi")
        let info = merged.catalog.entries[team.id]
        XCTAssertEqual(info?.summary.version, 2, "düzenlemenin dayandığı sürüm korunur")
        XCTAssertEqual(info?.summary.updatedBy, "bob", "kimin değiştirdiği gösterilebilir")
        XCTAssertEqual(info?.isDirty, true)
        XCTAssertEqual(info?.isLoaded, true)

        // Sunucu değişmediyse sorulmaz.
        let same = TeamSync.merge([summary("r1", version: 2, canUpdate: true)], into: [edited, mine], catalog: catalog, ownGroup: "gf-payments")
        XCTAssertTrue(same.remoteChanged.isEmpty)
    }

    /// Çevrimdışı açılışta salt okunura alınan kirli collection, liste yeniden
    /// alınınca düzenlenmeye döner (yeniden çekilmediği için başka yolu yok).
    func testDirtyCollectionBecomesEditableAgainAfterOfflineStart() {
        let (team, mine, loaded) = setup(canUpdate: true)
        var offline = loaded
        offline.entries[team.id]?.isDirty = true
        offline.entries[team.id]?.isLoaded = false
        XCTAssertFalse(offline.canEdit(team.id))

        let merged = TeamSync.merge([summary("r1", canUpdate: true)], into: [team, mine], catalog: offline, ownGroup: "gf-payments")
        XCTAssertTrue(merged.catalog.canEdit(team.id))
        XCTAssertEqual(merged.catalog.entries[team.id]?.isDirty, true)
        XCTAssertEqual(merged.collections.first { $0.id == team.id }, team, "yerel çalışma olduğu gibi")

        let noPermission = TeamSync.merge([summary("r1", canUpdate: false)], into: [team, mine], catalog: offline, ownGroup: "gf-payments")
        XCTAssertFalse(noPermission.catalog.canEdit(team.id), "yetki sunucudan; kalktıysa düzenlenmez")
    }

    func testReloadTargets() {
        func id(_ name: String) -> UUID { TeamCollectionCodec.stableID(name, "collection") }
        func info(_ name: String, loaded: Bool, dirty: Bool = false) -> TeamCollectionInfo {
            TeamCollectionInfo(summary: summary(name, canUpdate: true), isLoaded: loaded, isDirty: dirty)
        }
        let catalog = TeamCatalog(entries: [
            id("loaded"): info("loaded", loaded: true),
            id("dirty"): info("dirty", loaded: true, dirty: true),
            id("stale"): info("stale", loaded: false),          // sürümü değişti, daha önce çekilmişti, kapalı
            id("closed"): info("closed", loaded: false),        // hiç çekilmedi, kapalı
            id("open"): info("open", loaded: false),            // hiç çekilmedi, açık
        ])
        let order = ["loaded", "dirty", "stale", "closed", "open"].map(id)
        let collapsed: Set<UUID> = [id("stale"), id("closed")]

        let automatic = TeamSync.reloadTargets(order: order, catalog: catalog, previouslyLoaded: [id("loaded"), id("dirty"), id("stale")],
                                               collapsed: collapsed, reloadLoaded: false)
        XCTAssertEqual(automatic, [id("stale"), id("open")], "sürümü değişen çekilmiş collection kapalı olsa da güncellenir")

        let manual = TeamSync.reloadTargets(order: order, catalog: catalog, previouslyLoaded: [id("loaded"), id("dirty"), id("stale")],
                                            collapsed: collapsed, reloadLoaded: true)
        XCTAssertEqual(manual, [id("loaded"), id("stale"), id("open")], "Yenile: çekilmişlerin hepsi; kaydedilmemiş olan asla")
    }

    func testCacheRoundTripAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (team, _, catalog) = setup(canUpdate: true)
        let cache = TeamCache(identity: TeamIdentity(username: "alice", displayName: nil, group: "gf-payments"),
                              canCreate: true, catalog: catalog, collections: [team])
        try cache.save(root: root)
        XCTAssertEqual(TeamCache.load(root: root), cache)
        let permissions = try FileManager.default.attributesOfItem(atPath: TeamCache.url(root: root).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertFalse(String(decoding: try Data(contentsOf: TeamCache.url(root: root)), as: UTF8.self).contains("refresh"), "token yok")
        TeamCache.delete(root: root)
        XCTAssertNil(TeamCache.load(root: root))
    }
}
