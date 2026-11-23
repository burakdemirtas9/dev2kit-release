import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Yenileme akışı, lokal kurum servislerine karşı (yalnızca `DEV2KIT_TEAM_LIVE=1`).
/// Kendi oluşturduğu collection'ı siler.
@MainActor
final class AppStateTeamLiveTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEV2KIT_TEAM_LIVE"] == "1",
                          "Lokal kurum servisleri için DEV2KIT_TEAM_LIVE=1")
        harness = AppStateHarness()
    }

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
    }

    func testRefreshUpdatesLoadedCollectionsAndAsksBeforeOverwritingLocalWork() async throws {
        let failure = await state.teamLogin(username: "alice", password: "alice-local-only")
        XCTAssertNil(failure)

        // "Başka pencere": aynı kullanıcı, ayrı oturum.
        let otherSession = TeamSession(config: .default, refreshTokenStore: InMemorySecretStore(), hostPolicy: { .notConfigured })
        _ = try await otherSession.login(username: "alice", password: "alice-local-only")
        let other = TeamDataClient(session: otherSession)

        let name = "E2E yenile \(UUID().uuidString.prefix(8))"
        func content(_ url: String) throws -> Data {
            try TeamCollectionCodec.encode(CollectionModel(name: name, requests: [
                RequestModel(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "istek", method: .get, url: url),
            ]))
        }
        let created = try await other.create(name: name, content: try content("https://api.example.com/v1"))
        let remoteID = created.summary.id
        addTeardownBlock { try? await other.delete(id: remoteID); await otherSession.logout() }
        let id = TeamCollectionCodec.stableID(remoteID, "collection")
        func localURL() -> String? { state.workspace.collections.first { $0.id == id }?.requests.first?.url }

        await state.teamRefresh(reloadLoaded: true)
        XCTAssertEqual(localURL(), "https://api.example.com/v1")

        // 1) Yerelde değişiklik yok, sunucu değişti: Yenile kendiliğinden günceller (collection kapalı olsa da).
        state.collapsedCollectionIDs.insert(id)
        let v2 = try await other.update(id: remoteID, name: name, content: try content("https://api.example.com/v2"), version: created.summary.version)
        await state.teamRefresh(reloadLoaded: true)
        XCTAssertEqual(localURL(), "https://api.example.com/v2")
        XCTAssertTrue(state.teamRemoteChangedIDs.isEmpty)

        // 2) Yerelde kaydedilmemiş değişiklik var, sunucu değişti: ezilmez, sorulur.
        let index = try XCTUnwrap(state.workspace.collections.firstIndex { $0.id == id })
        state.workspace.collections[index].requests[0].url = "https://api.example.com/benim"
        XCTAssertEqual(state.teamCatalog.entries[id]?.isDirty, true)
        _ = try await other.update(id: remoteID, name: name, content: try content("https://api.example.com/v3"), version: v2.summary.version)
        await state.teamRefresh(reloadLoaded: true)
        XCTAssertEqual(localURL(), "https://api.example.com/benim", "yerel çalışma ezilmedi")
        XCTAssertEqual(state.teamRemoteChangedIDs, [id])

        // "Benimkini koru": çalışma kalır; kaydetmek sessizce ezmez, çakışma sorulur.
        await state.teamResolveRemoteChange(id, loadServer: false)
        XCTAssertEqual(localURL(), "https://api.example.com/benim")
        await state.teamSave(id)
        XCTAssertEqual(state.teamConflictID, id, "eski sürümle kayıt 409 alır")
        state.teamConflictID = nil

        // Yeniden yenile → yine sorulur; "Sunucudakini yükle": yerel değişiklik gider.
        await state.teamRefresh(reloadLoaded: true)
        XCTAssertEqual(state.teamRemoteChangedIDs, [id])
        await state.teamResolveRemoteChange(id, loadServer: true)
        XCTAssertEqual(localURL(), "https://api.example.com/v3")
        XCTAssertEqual(state.teamCatalog.entries[id]?.isDirty, false)
        XCTAssertTrue(state.teamRemoteChangedIDs.isEmpty)

        // Başlıktaki "Sunucuya kaydet": kaydedilmemiş collection'ı kaydeder.
        let reloaded = try XCTUnwrap(state.workspace.collections.firstIndex { $0.id == id })
        state.workspace.collections[reloaded].requests[0].url = "https://api.example.com/hepsi"
        await state.teamSaveAll()
        XCTAssertEqual(state.teamCatalog.entries[id]?.isDirty, false)
        XCTAssertFalse(state.teamIsSavingAll)
        await state.teamRefresh(reloadLoaded: true)
        XCTAssertEqual(localURL(), "https://api.example.com/hepsi", "sunucuya gitti")

        await state.teamLogout()
    }
}
