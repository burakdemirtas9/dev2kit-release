import XCTest
@testable import Dev2KitCore

/// Kurum oturumu ve veri istemcisi, rehberdeki kurallarla (2026-11-11).
final class TeamSessionTests: XCTestCase {
    private var service: FakeTeamService!

    override func setUp() async throws {
        service = FakeTeamService()
        try await service.start()
    }

    private func session(store: SecretStore? = InMemorySecretStore()) -> TeamSession {
        TeamSession(config: service.config, refreshTokenStore: store, hostPolicy: { .notConfigured })
    }

    func testLoginStoresRefreshTokenOnlyAndRestoreRotatesIt() async throws {
        let store = InMemorySecretStore()
        let first = session(store: store)
        let identity = try await first.login(username: "alice", password: "alice-local-only")
        XCTAssertEqual(identity, TeamIdentity(username: "alice", displayName: "Alice Admin", group: "gf-payments"))
        let stored = try XCTUnwrap(try store.secret(forName: TeamSession.refreshTokenName))
        XCTAssertTrue(stored.hasPrefix("refresh-alice"))
        XCTAssertEqual(try store.listSecretNames(), [TeamSession.refreshTokenName], "parola ya da access token saklanmaz")

        // Yeniden açılış: saklı refresh token ile içeride; token değişti.
        let reopened = session(store: store)
        let restored = try await reopened.restore()
        XCTAssertEqual(restored?.username, "alice")
        XCTAssertNotEqual(try store.secret(forName: TeamSession.refreshTokenName), stored, "refresh token her kullanımda değişir")
        let none = try await session().restore()
        XCTAssertNil(none, "saklı token yoksa login ekranı")
    }

    func testLoginErrorsAreMappedAndNeverRetried() async throws {
        let session = session()
        await assertThrows(TeamError.invalidCredentials) { _ = try await session.login(username: "alice", password: "yanlış") }
        XCTAssertEqual(service.loginCalls, 1, "başarısız login otomatik tekrarlanmaz")
        await assertThrows(TeamError.invalidCredentials) { _ = try await session.login(username: "carol", password: "carol-local-only") }
        await assertThrows(TeamError.passwordChangeRequired) { _ = try await session.login(username: "pat", password: "x") }
        await assertThrows(TeamError.invalidUsername) { _ = try await session.login(username: "alice@firma.com", password: "x") }
        await assertThrows(TeamError.invalidUsername) { _ = try await session.login(username: "FIRMA\\alice", password: "x") }
        for _ in 0..<4 { _ = try? await session.login(username: "bob", password: "yanlış") }
        _ = try? await session.login(username: "bob", password: "yanlış")
        await assertThrows(TeamError.tooManyAttempts(retryAfter: 42)) { _ = try await session.login(username: "bob", password: "yanlış") }
    }

    func testConcurrent401sShareASingleRefresh() async throws {
        let session = session()
        _ = try await session.login(username: "alice", password: "alice-local-only")
        let client = TeamDataClient(session: session)
        service.expireAccessTokens()
        let before = service.refreshCalls
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<10 { group.addTask { try await client.list().count } }
            for try await _ in group {}
        }
        XCTAssertEqual(service.refreshCalls - before, 1, "aynı anda gelen 401'ler tek refresh'i bekler")
        let identity = await session.identity
        XCTAssertNotNil(identity, "oturum düşmedi (eski token tekrar kullanılmadı)")
    }

    func testExpiredRefreshEndsTheSession() async throws {
        let store = InMemorySecretStore()
        let session = session(store: store)
        _ = try await session.login(username: "alice", password: "alice-local-only")
        try store.setSecret("refresh-geçersiz", forName: TeamSession.refreshTokenName)
        let other = self.session(store: store)
        await assertThrows(TeamError.sessionExpired) { _ = try await other.restore() }
        XCTAssertNil(try store.secret(forName: TeamSession.refreshTokenName), "oturum bitince token silinir")
    }

    func testProactiveRefreshWhenAccessTokenIsAboutToExpire() async throws {
        service.accessTokenLifetime = 30
        let session = session()
        _ = try await session.login(username: "alice", password: "alice-local-only")
        _ = try await TeamDataClient(session: session).me()
        XCTAssertEqual(service.refreshCalls, 1, "60 sn'den az kaldıysa istekten önce yenilenir")
    }

    func testRefreshTokenNeverGoesToTheDataService() async throws {
        let session = session()
        _ = try await session.login(username: "alice", password: "alice-local-only")
        let client = TeamDataClient(session: session)
        _ = try await client.me()
        service.expireAccessTokens()
        _ = try await client.list()
        XCTAssertEqual(service.dataRequestsWithRefreshToken, 0)
    }

    func testLogoutClearsEverythingEvenIfTheServiceIsDown() async throws {
        let store = InMemorySecretStore()
        let session = TeamSession(config: TeamConfig(authBaseURL: URL(string: "http://127.0.0.1:1")!, dataBaseURL: URL(string: "http://127.0.0.1:1")!),
                                  refreshTokenStore: store, hostPolicy: { .notConfigured })
        try store.setSecret("refresh-x", forName: TeamSession.refreshTokenName)
        await session.logout()
        XCTAssertNil(try store.secret(forName: TeamSession.refreshTokenName))
        let identity = await session.identity
        XCTAssertNil(identity)
    }

    func testCollectionPermissionsConflictsAndErrors() async throws {
        let alice = session()
        _ = try await alice.login(username: "alice", password: "alice-local-only")
        let aliceClient = TeamDataClient(session: alice)
        let me = try await aliceClient.me()
        XCTAssertTrue(me.canCreate)
        let created = try await aliceClient.create(name: "Payments API", content: Data(#"{"requests":[]}"#.utf8))
        XCTAssertEqual(created.summary.version, 0)
        await assertThrows(TeamError.nameTaken) { _ = try await aliceClient.create(name: "Payments API", content: Data("{}".utf8)) }
        await assertThrows(TeamError.invalidName) { _ = try await aliceClient.create(name: "-kötü ad", content: Data("{}".utf8)) }
        await assertThrows(TeamError.invalidRequest) { _ = try await aliceClient.create(name: "Dizi", content: Data("[1]".utf8)) }

        let bob = session()
        _ = try await bob.login(username: "bob", password: "bob-local-only")
        let bobClient = TeamDataClient(session: bob)
        let seen = try await bobClient.list().first { $0.id == created.summary.id }
        XCTAssertEqual(seen?.canUpdate, false)
        await assertThrows(TeamError.forbidden) {
            _ = try await bobClient.update(id: created.summary.id, name: "Payments API", content: Data("{}".utf8), version: 0)
        }

        let updated = try await aliceClient.update(id: created.summary.id, name: "Payments API", content: Data(#"{"requests":[]}"#.utf8), version: 0)
        XCTAssertEqual(updated.summary.version, 1)
        await assertThrows(TeamError.versionConflict) {
            _ = try await aliceClient.update(id: created.summary.id, name: "Payments API", content: Data("{}".utf8), version: 0)
        }
        try await aliceClient.delete(id: created.summary.id)
        await assertThrows(TeamError.notFound) { _ = try await aliceClient.fetch(id: created.summary.id) }
        await assertThrows(TeamError.invalidResponse) { _ = try await aliceClient.fetch(id: "../auth/logout") }
    }

    func testAddressRule() {
        XCTAssertTrue(TeamConfig.isAllowed(URL(string: "https://auth.firma.com")!))
        XCTAssertTrue(TeamConfig.isAllowed(URL(string: "http://127.0.0.1:8080")!))
        XCTAssertTrue(TeamConfig.isAllowed(URL(string: "http://localhost:8081")!))
        XCTAssertFalse(TeamConfig.isAllowed(URL(string: "http://auth.firma.com")!), "parola düz http'den gitmez")
        XCTAssertFalse(TeamConfig.isAllowed(URL(string: "ftp://x")!))
        XCTAssertEqual(TeamConfig.default.authBaseURL.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(TeamConfig.default.dataBaseURL.absoluteString, "http://127.0.0.1:8082")
    }

    func testInsecureServiceIsRefused() async throws {
        let session = TeamSession(config: TeamConfig(authBaseURL: URL(string: "http://auth.firma.test")!, dataBaseURL: URL(string: "http://data.firma.test")!),
                                  refreshTokenStore: nil, hostPolicy: { .notConfigured })
        await assertThrows(TeamError.insecureURL) { _ = try await session.login(username: "alice", password: "x") }
    }

    private func assertThrows(_ expected: TeamError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("hata bekleniyordu: \(expected)", file: file, line: line)
        } catch let error as TeamError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("beklenmeyen hata: \(error)", file: file, line: line)
        }
    }

    func testCollectionNameRuleMatchesServer() {
        for name in ["Payments API", "a", "9 lives", "v2 (beta)/x_y-z.1", "Ödemeler", "Kart işlemleri", String(repeating: "a", count: 120)] {
            XCTAssertTrue(TeamDataClient.isValidName(name), name)
        }
        for name in ["", " bosluk", "-tire", "a:b", "a@b", "a\nb", String(repeating: "a", count: 121)] {
            XCTAssertFalse(TeamDataClient.isValidName(name), name)
        }
    }
}
