import XCTest
@testable import Dev2KitCore

/// Güvenlik incelemesi F1 (2026-10-20): yönlendirmede hassas başlık başka
/// kaynağa (origin) taşınmamalı. Önceden liste ham modelden çıkarılıyor,
/// yalnızca bitişik `{{secret:` metni tanınıyordu; dolaylı referans,
/// boşluklu referans, değişkenle verilen başlık adı ve düz metin kimlik
/// başlığı hedefe ulaşıyordu. Değerler sentetiktir.
final class RedirectCredentialTests: XCTestCase {
    private let secret = "SYNTHETIC-VAULT-TOKEN-0123456789"
    private var store: InMemorySecretStore { InMemorySecretStore(initial: ["audit": secret]) }

    /// A (bir port) B'ye (başka port = başka kaynak) yönlendirir; B'ye ne ulaştı.
    private func crossOriginRedirect(headers: [KeyValueEntry], environment: EnvironmentModel? = nil,
                                     auth: AuthConfig = .none, status: Int = 302) async throws -> String {
        let target = try LoopbackHTTPServer()
        let targetPort = try await target.start()
        let source = try LoopbackHTTPServer { _ in LoopbackHTTPServer.redirect(status, to: "http://127.0.0.1:\(targetPort)/b") }
        let sourcePort = try await source.start()
        let model = RequestModel(url: "http://127.0.0.1:\(sourcePort)/a", headers: headers, auth: auth)
        let response = try await RequestEngine().sendApprovingWarnings(model, environment: environment, secretStore: store)
        XCTAssertEqual(response.statusCode, 200)
        let raw = target.received.first ?? ""
        XCTAssertTrue(raw.hasPrefix("GET /b "), "yönlendirme hedefine istek ulaşmalı: \(raw)")
        return raw
    }

    func testIndirectSecretThroughEnvironmentIsStripped() async throws {
        let environment = EnvironmentModel(name: "e", variables: [KeyValueEntry(key: "alias", value: "{{secret:audit}}")])
        let raw = try await crossOriginRedirect(headers: [KeyValueEntry(key: "X-Indirect-Key", value: "{{alias}}")], environment: environment)
        XCTAssertFalse(raw.contains(secret), raw)
    }

    func testSpacedSecretReferenceIsStripped() async throws {
        let raw = try await crossOriginRedirect(headers: [KeyValueEntry(key: "X-Spaced-Key", value: "{{ secret:audit }}")])
        XCTAssertFalse(raw.contains(secret), raw)
    }

    func testDynamicHeaderNameIsStripped() async throws {
        let environment = EnvironmentModel(name: "e", variables: [KeyValueEntry(key: "headerName", value: "X-Dynamic-Key")])
        let raw = try await crossOriginRedirect(headers: [KeyValueEntry(key: "{{headerName}}", value: "{{secret:audit}}")], environment: environment)
        XCTAssertFalse(raw.contains(secret), raw)
    }

    func testLiteralCredentialHeaderIsStripped() async throws {
        let raw = try await crossOriginRedirect(headers: [KeyValueEntry(key: "X-Auth-Token", value: "SYNTHETIC-LITERAL-TOKEN-abcdef0123")])
        XCTAssertFalse(raw.contains("SYNTHETIC-LITERAL-TOKEN"), raw)
    }

    func testDynamicAPIKeyHeaderNameIsStripped() async throws {
        let environment = EnvironmentModel(name: "e", variables: [KeyValueEntry(key: "keyHeader", value: "X-Partner-Key")])
        let raw = try await crossOriginRedirect(headers: [], environment: environment,
                                                auth: .apiKey(key: "{{keyHeader}}", value: "{{secret:audit}}", location: .header))
        XCTAssertFalse(raw.contains(secret), raw)
    }

    func testPermanentRedirectAlsoStrips() async throws {
        let raw = try await crossOriginRedirect(headers: [KeyValueEntry(key: "X-Direct-Key", value: "{{secret:audit}}")], status: 307)
        XCTAssertFalse(raw.contains(secret), raw)
    }

    /// Kontrol: hassas olmayan başlık taşınır (gereksiz yere düşürülmez).
    func testOrdinaryHeaderIsKept() async throws {
        let raw = try await crossOriginRedirect(headers: [KeyValueEntry(key: "X-Trace-Note", value: "plain")])
        XCTAssertTrue(raw.lowercased().contains("x-trace-note: plain"), raw)
    }

    /// Kontrol: aynı kaynağa yönlendirmede hassas başlık korunur.
    func testSameOriginRedirectKeepsTheSecretHeader() async throws {
        let server = try LoopbackHTTPServer { raw in
            raw.hasPrefix("GET /a ") ? LoopbackHTTPServer.redirect(302, to: "/b") : LoopbackHTTPServer.ok("ok")
        }
        let port = try await server.start()
        let model = RequestModel(url: "http://127.0.0.1:\(port)/a", headers: [KeyValueEntry(key: "X-Spaced-Key", value: "{{ secret:audit }}")])
        _ = try await RequestEngine().sendApprovingWarnings(model, secretStore: store)
        let second = server.received.last ?? ""
        XCTAssertTrue(second.hasPrefix("GET /b "), second)
        XCTAssertTrue(second.contains(secret), "aynı kaynakta başlık kalır")
    }
}
