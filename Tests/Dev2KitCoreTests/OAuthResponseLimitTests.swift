import XCTest
@testable import Dev2KitCore

/// Güvenlik incelemesi (2026-10-21): token yanıtı sınırsız belleğe alınıyordu.
/// Token adresi içe aktarılan koleksiyondan gelebilir; dev yanıt (ya da gzip
/// bombası) belleği doldurmasın. Yerel sunucu, sentetik veri.
final class OAuthResponseLimitTests: XCTestCase {
    private func refresh(_ port: UInt16) async throws -> OAuth2Token {
        let config = OAuth2Config(tokenURL: "http://127.0.0.1:\(port)/token", clientID: "client")
        return try await OAuth2Service(timeout: 10).refresh(config: config, refreshToken: "SYNTHETIC-REFRESH",
                                                            resolvedClientSecret: nil, hostPolicy: .notConfigured)
    }

    func testOversizedTokenResponseIsRejected() async throws {
        let huge = #"{"access_token":""# + String(repeating: "a", count: 2_000_000) + #"","token_type":"Bearer"}"#
        let server = try LoopbackHTTPServer { _ in LoopbackHTTPServer.ok(huge, contentType: "application/json") }
        let port = try await server.start()
        do {
            _ = try await refresh(port)
            XCTFail("sınırı aşan yanıt kabul edilmemeli")
        } catch let error as OAuth2Client.FlowError {
            XCTAssertTrue(error.message.contains("1"), error.message)
        }
    }

    func testNormalTokenResponseStillWorks() async throws {
        let json = #"{"access_token":"SYNTHETIC-ACCESS","token_type":"Bearer","expires_in":60}"#
        let server = try LoopbackHTTPServer { _ in LoopbackHTTPServer.ok(json, contentType: "application/json") }
        let token = try await refresh(try await server.start())
        XCTAssertEqual(token.accessToken, "SYNTHETIC-ACCESS")
    }
}
