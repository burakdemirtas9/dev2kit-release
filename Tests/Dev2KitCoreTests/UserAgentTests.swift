import XCTest
@testable import Dev2KitCore

/// User-Agent sabit ve ezilemez (kullanıcı kararı, 2026-10-18/19): test
/// trafiği sunucu loglarında ayırt edilsin, araç başka kimliğe bürünmesin.
final class UserAgentTests: XCTestCase {
    private let engine = RequestEngine()
    private let resolver = VariableResolver(environment: nil, secretStore: InMemorySecretStore())

    func testValueIsTheDecidedVersion() {
        XCTAssertEqual(Dev2KitIdentity.userAgent, "dev2kit-v1.2")
    }

    func testEngineSendsDev2KitUserAgent() throws {
        let request = RequestModel(name: "r", method: .get, url: "https://a.example.com")
        XCTAssertEqual(try engine.buildURLRequest(request, resolver: resolver).value(forHTTPHeaderField: "User-Agent"), Dev2KitIdentity.userAgent)
    }

    func testUserCannotOverrideIt() throws {
        for name in ["User-Agent", "user-agent", " USER-AGENT "] {
            var request = RequestModel(name: "r", method: .get, url: "https://a.example.com")
            request.headers = [KeyValueEntry(key: name, value: "Mozilla/5.0 (iPhone)")]
            XCTAssertEqual(try engine.buildURLRequest(request, resolver: resolver).value(forHTTPHeaderField: "User-Agent"), Dev2KitIdentity.userAgent, name)
        }
        // Auth'taki API key başlığı da ezemez.
        var viaAuth = RequestModel(name: "r", method: .get, url: "https://a.example.com")
        viaAuth.auth = .apiKey(key: "User-Agent", value: "FinanceApp/4.28.1", location: .header)
        XCTAssertEqual(try engine.buildURLRequest(viaAuth, resolver: resolver).value(forHTTPHeaderField: "User-Agent"), Dev2KitIdentity.userAgent)
    }

    func testIgnoredUserAgentWithHiddenCharactersDoesNotBlockTheRequest() throws {
        // Yok sayılan satır güvenlik denetimine de takılmaz (gönderilmiyor).
        var request = RequestModel(name: "r", method: .get, url: "https://a.example.com")
        request.headers = [KeyValueEntry(key: "User-Agent", value: "x\r\nX-Injected: 1")]
        XCTAssertNoThrow(try engine.buildURLRequest(request, resolver: resolver))
    }

    func testTokenRequestsCarryItToo() throws {
        let config = OAuth2Config(authorizationURL: "https://idp.example.com/authorize", tokenURL: "https://idp.example.com/token",
                                  clientID: "istemci", scopes: "openid")
        let refresh = try OAuth2Client.refreshRequest(config: config, refreshToken: "r", resolvedClientSecret: nil)
        XCTAssertEqual(refresh.value(forHTTPHeaderField: "User-Agent"), Dev2KitIdentity.userAgent)
    }

    func testUserAgentRowIsNotCounted() {
        var request = RequestModel(name: "r", method: .get, url: "https://a.example.com")
        request.headers = [KeyValueEntry(key: "Accept", value: "*/*"), KeyValueEntry(key: "User-Agent", value: "x")]
        XCTAssertEqual(request.activeHeaderCount, 1)
    }

    func testCurlExportLeavesItOut() throws {
        // Dışa aktarılan komut curl ile çalışır; dev2kit trafiği değildir.
        let curl = try CurlExporter.export(RequestModel(method: .get, url: "https://a.example.com"), environment: nil, secretStore: InMemorySecretStore())
        XCTAssertFalse(curl.contains("User-Agent"))
    }
}
