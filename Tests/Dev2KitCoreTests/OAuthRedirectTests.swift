import XCTest
@testable import Dev2KitCore

/// Güvenlik incelemesi F3 (2026-10-20): token isteğinin gövdesi (client
/// secret, refresh token) yönlendirmeyle başka bir kaynağa taşınmamalı.
/// Önceden 307 ile B'ye giden POST gövdesi B'ye ulaşıyor, B'nin token'ı
/// kabul ediliyordu. Değerler sentetiktir.
final class OAuthRedirectTests: XCTestCase {
    private let tokenJSON = #"{"access_token":"SYNTHETIC-ACCESS","token_type":"Bearer","expires_in":60}"#

    private func refresh(tokenURL: String) async throws -> OAuth2Token {
        let config = OAuth2Config(tokenURL: tokenURL, clientID: "client", clientSecret: "SYNTHETIC-CLIENT")
        return try await OAuth2Service(timeout: 5).refresh(
            config: config, refreshToken: "SYNTHETIC-REFRESH",
            resolvedClientSecret: "SYNTHETIC-CLIENT", hostPolicy: .notConfigured
        )
    }

    func testCrossOriginRedirectOfTheTokenRequestIsRefused() async throws {
        let json = tokenJSON
        let attacker = try LoopbackHTTPServer { _ in LoopbackHTTPServer.ok(json, contentType: "application/json") }
        let attackerPort = try await attacker.start()
        for status in [307, 308] {
            let provider = try LoopbackHTTPServer { _ in LoopbackHTTPServer.redirect(status, to: "http://127.0.0.1:\(attackerPort)/token") }
            let providerPort = try await provider.start()
            do {
                _ = try await refresh(tokenURL: "http://127.0.0.1:\(providerPort)/token")
                XCTFail("\(status): başka kaynağın token'ı kabul edilmemeli")
            } catch let error as OAuth2Client.FlowError {
                XCTAssertTrue(error.message.contains("127.0.0.1"), error.message)
            }
            XCTAssertEqual(provider.received.count, 1)
        }
        XCTAssertTrue(attacker.received.isEmpty, "client secret / refresh token başka kaynağa gitmemeli")
    }

    /// Kontrol: aynı kaynak içindeki yönlendirme çalışmaya devam eder.
    func testSameOriginRedirectStillWorks() async throws {
        let json = tokenJSON
        let provider = try LoopbackHTTPServer { raw in
            raw.contains(" /old ") ? LoopbackHTTPServer.redirect(307, to: "/token")
                                   : LoopbackHTTPServer.ok(json, contentType: "application/json")
        }
        let port = try await provider.start()
        let token = try await refresh(tokenURL: "http://127.0.0.1:\(port)/old")
        XCTAssertEqual(token.accessToken, "SYNTHETIC-ACCESS")
        XCTAssertEqual(provider.received.count, 2)
        XCTAssertTrue(provider.received[1].contains("SYNTHETIC-REFRESH"), "gövde aynı kaynakta korunur (307)")
    }

    func testDowngradeAndForeignHostsAreNotAllowed() {
        let https = URL(string: "https://idp.example.com/token")
        XCTAssertFalse(PolicyRedirectGuard.allows(from: https, to: URL(string: "http://idp.example.com/token"), policy: .notConfigured))
        XCTAssertFalse(PolicyRedirectGuard.allows(from: https, to: URL(string: "https://evil.example.com/token"), policy: .notConfigured))
        XCTAssertFalse(PolicyRedirectGuard.allows(from: https, to: URL(string: "https://idp.example.com:8443/token"), policy: .notConfigured))
        XCTAssertTrue(PolicyRedirectGuard.allows(from: https, to: URL(string: "https://idp.example.com/v2/token"), policy: .notConfigured))
    }
}
