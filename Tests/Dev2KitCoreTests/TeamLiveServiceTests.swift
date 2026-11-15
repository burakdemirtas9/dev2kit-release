import XCTest
@testable import Dev2KitCore

/// Lokal dev2kit-auth (8080) + dev2kit-data (8082) ile uçtan uca kontrol
/// (rehber §9). Servis gerektirdiği için yalnızca `DEV2KIT_TEAM_LIVE=1` ile
/// çalışır; normal `swift test`'te atlanır. Kendi oluşturduğu collection'ı siler.
final class TeamLiveServiceTests: XCTestCase {
    /// Testin saati: ileri alınınca access token "bitmek üzere" görünür.
    private final class Clock: @unchecked Sendable {
        var offset: TimeInterval = 0
        func now() -> Date { Date().addingTimeInterval(offset) }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEV2KIT_TEAM_LIVE"] == "1",
                          "Lokal kurum servisleri için DEV2KIT_TEAM_LIVE=1")
    }

    private func session(_ clock: Clock = Clock()) -> TeamSession {
        TeamSession(config: .default, refreshTokenStore: InMemorySecretStore(),
                    hostPolicy: { .notConfigured }, now: { clock.now() })
    }

    func testLoginOutcomesMatchGuide() async throws {
        let s = session()
        let alice = try await s.login(username: "alice", password: "alice-local-only")
        XCTAssertEqual(alice.group, "gf-payments")
        let me = try await TeamDataClient(session: s).me()
        XCTAssertTrue(me.canCreate)

        for user in ["carol", "dave"] {
            do { _ = try await session().login(username: user, password: "\(user)-local-only"); XCTFail(user) }
            catch { XCTAssertEqual(error as? TeamError, .invalidCredentials, user) }
        }
        let frank = session()
        _ = try await frank.login(username: "frank", password: "frank-local-only")
        let frankMe = try await TeamDataClient(session: frank).me()
        XCTAssertFalse(frankMe.canCreate)
        await s.logout()
        await frank.logout()
    }

    /// alice oluşturur → bob açar (salt okunur, PUT/DELETE 403) → iki pencerede
    /// aynı sürümle güncelleme (ikincisi 409) → uygulamanın kodlayıcısıyla gidiş-dönüş → sil.
    func testScenarioFromGuide() async throws {
        let aliceSession = session(), bobSession = session()
        _ = try await aliceSession.login(username: "alice", password: "alice-local-only")
        _ = try await bobSession.login(username: "bob", password: "bob-local-only")
        let alice = TeamDataClient(session: aliceSession), bob = TeamDataClient(session: bobSession)

        let name = "E2E \(UUID().uuidString.prefix(8))"
        let request = RequestModel(name: "charge", method: .post, url: "https://api.example.com/charge")
        let content = try TeamCollectionCodec.encode(CollectionModel(name: name, requests: [request]))
        let created = try await alice.create(name: name, content: content)
        defer { Task { try? await alice.delete(id: created.summary.id); await aliceSession.logout(); await bobSession.logout() } }
        XCTAssertTrue(created.summary.canUpdate)

        do { _ = try await alice.create(name: name, content: content); XCTFail("aynı ad") }
        catch { XCTAssertEqual(error as? TeamError, .nameTaken) }

        let listed = try await bob.list().first { $0.id == created.summary.id }
        XCTAssertEqual(listed?.canUpdate, false)
        XCTAssertEqual(listed?.canDelete, false)
        let opened = try await bob.fetch(id: created.summary.id)
        let decoded = try TeamCollectionCodec.decode(opened.content, remoteID: opened.summary.id, name: opened.summary.name)
        XCTAssertEqual(decoded.collection.requests.map(\.url), ["https://api.example.com/charge"])
        XCTAssertEqual(decoded.collection.requests.first?.method, .post)
        do { _ = try await bob.update(id: created.summary.id, name: name, content: content, version: created.summary.version); XCTFail("bob PUT") }
        catch { XCTAssertEqual(error as? TeamError, .forbidden) }
        do { try await bob.delete(id: created.summary.id); XCTFail("bob DELETE") }
        catch { XCTAssertEqual(error as? TeamError, .forbidden) }

        let first = try await alice.update(id: created.summary.id, name: name, content: content, version: created.summary.version)
        XCTAssertEqual(first.summary.version, created.summary.version + 1)
        do { _ = try await alice.update(id: created.summary.id, name: name, content: content, version: created.summary.version); XCTFail("eski sürüm") }
        catch { XCTAssertEqual(error as? TeamError, .versionConflict) }

        // Rehberdeki eksik alanlı içerik de açılır.
        let minimal = try await alice.create(name: name + " min", content: Data(#"{"requests":[{"name":"charge","method":"POST"}]}"#.utf8))
        let minimalDecoded = try TeamCollectionCodec.decode(minimal.content, remoteID: minimal.summary.id, name: minimal.summary.name)
        XCTAssertEqual(minimalDecoded.collection.requests.map(\.name), ["charge"])
        try await alice.delete(id: minimal.summary.id)

        try await alice.delete(id: created.summary.id)
        do { _ = try await alice.fetch(id: created.summary.id); XCTFail("silinen") }
        catch { XCTAssertEqual(error as? TeamError, .notFound) }
    }

    /// Servis eski refresh token tekrar kullanılınca oturumun tamamını iptal
    /// ediyor. Token bitmek üzereyken aynı anda 10 istek: tek refresh olmalı,
    /// oturum düşmemeli.
    func testConcurrentRefreshKeepsSessionAlive() async throws {
        let clock = Clock()
        let s = session(clock)
        _ = try await s.login(username: "alice", password: "alice-local-only")
        let client = TeamDataClient(session: s)
        clock.offset = 14.5 * 60
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = try await client.list() } }
            try await group.waitForAll()
        }
        clock.offset = 0
        _ = try await client.me()
        let identity = await s.identity
        XCTAssertNotNil(identity)

        await s.logout()
        do { _ = try await s.refresh(); XCTFail("çıkıştan sonra") }
        catch { XCTAssertEqual(error as? TeamError, .sessionExpired) }
    }
}
