import XCTest
@testable import Dev2KitCore

final class PKCETests: XCTestCase {
    func testVerifierLengthWithinRFCRange() {
        let pkce = PKCE.generate()
        // RFC 7636 §4.1: 43-128 karakter.
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertLessThanOrEqual(pkce.verifier.count, 128)
    }

    func testVerifierIsBase64URLSafe() {
        let pkce = PKCE.generate()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertNil(pkce.verifier.rangeOfCharacter(from: allowed.inverted))
        XCTAssertFalse(pkce.verifier.contains("="))
        XCTAssertFalse(pkce.verifier.contains("+"))
        XCTAssertFalse(pkce.verifier.contains("/"))
    }

    func testEachGenerationIsUnique() {
        let values = Set((0..<50).map { _ in PKCE.generate().verifier })
        XCTAssertEqual(values.count, 50, "verifier tahmin edilebilir olmamalı")
    }

    func testChallengeMatchesRFCExample() {
        // RFC 7636 Appendix B'deki referans vektör.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testMethodIsAlwaysS256() {
        // "plain" desteklenmemeli: challenge = verifier PKCE'yi anlamsız kılar.
        XCTAssertEqual(PKCE.generate().method, "S256")
    }

    func testStateIsUniqueAndNonEmpty() {
        let states = Set((0..<50).map { _ in PKCE.generateState() })
        XCTAssertEqual(states.count, 50)
        XCTAssertFalse(states.contains(""))
    }
}

final class OAuth2ClientTests: XCTestCase {
    private func makeConfig() -> OAuth2Config {
        OAuth2Config(
            authorizationURL: "https://idp.example.com/authorize",
            tokenURL: "https://idp.example.com/token",
            clientID: "istemci-123",
            scopes: "openid profile"
        )
    }

    private func queryItems(_ url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    // MARK: - Yetkilendirme adresi

    func testAuthorizationURLContainsRequiredParameters() throws {
        let pkce = PKCE.generate()
        let url = try OAuth2Client.authorizationURL(
            config: makeConfig(),
            pkce: pkce,
            state: "durum-abc",
            redirectURI: "http://127.0.0.1:51234/callback"
        )
        let items = queryItems(url)
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "istemci-123")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:51234/callback")
        XCTAssertEqual(items["state"], "durum-abc")
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["scope"], "openid profile")
    }

    func testAuthorizationURLNeverSendsVerifier() throws {
        let pkce = PKCE.generate()
        let url = try OAuth2Client.authorizationURL(
            config: makeConfig(), pkce: pkce, state: "s", redirectURI: "http://127.0.0.1:1/callback"
        )
        // Verifier yetkilendirme isteğinde GİTMEZ; giderse PKCE anlamsız olur.
        XCTAssertFalse(url.absoluteString.contains(pkce.verifier))
    }

    func testExtraParametersAreIncluded() throws {
        var config = makeConfig()
        config.extraParameters = [
            KeyValueEntry(key: "audience", value: "https://api.example.com"),
            KeyValueEntry(key: "kapali", value: "x", enabled: false),
        ]
        let url = try OAuth2Client.authorizationURL(
            config: config, pkce: .generate(), state: "s", redirectURI: "http://127.0.0.1:1/callback"
        )
        let items = queryItems(url)
        XCTAssertEqual(items["audience"], "https://api.example.com")
        XCTAssertNil(items["kapali"])
    }

    func testInvalidAuthorizationURLThrows() {
        var config = makeConfig()
        config.authorizationURL = "bu bir url değil"
        XCTAssertThrowsError(try OAuth2Client.authorizationURL(
            config: config, pkce: .generate(), state: "s", redirectURI: "http://127.0.0.1:1/callback"
        ))
    }

    func testEmptyClientIDThrows() {
        var config = makeConfig()
        config.clientID = "  "
        XCTAssertThrowsError(try OAuth2Client.authorizationURL(
            config: config, pkce: .generate(), state: "s", redirectURI: "http://127.0.0.1:1/callback"
        ))
    }

    // MARK: - Callback ve state doğrulaması

    func testValidCallbackReturnsCode() throws {
        let url = URL(string: "http://127.0.0.1:5/callback?code=kod-123&state=durum")!
        XCTAssertEqual(try OAuth2Client.authorizationCode(from: url, expectedState: "durum"), "kod-123")
    }

    func testMismatchedStateIsRejected() {
        // Kod enjeksiyonu / CSRF savunması: state tutmuyorsa kod kullanılmaz.
        let url = URL(string: "http://127.0.0.1:5/callback?code=kod&state=saldirgan")!
        XCTAssertThrowsError(try OAuth2Client.authorizationCode(from: url, expectedState: "benim-durumum"))
    }

    func testMissingStateIsRejected() {
        let url = URL(string: "http://127.0.0.1:5/callback?code=kod")!
        XCTAssertThrowsError(try OAuth2Client.authorizationCode(from: url, expectedState: "durum"))
    }

    func testProviderErrorIsSurfaced() {
        let url = URL(string: "http://127.0.0.1:5/callback?error=access_denied&error_description=Kullanici%20reddetti&state=durum")!
        XCTAssertThrowsError(try OAuth2Client.authorizationCode(from: url, expectedState: "durum")) { error in
            XCTAssertTrue(error.localizedDescription.contains("access_denied"))
        }
    }

    func testMissingCodeIsRejected() {
        let url = URL(string: "http://127.0.0.1:5/callback?state=durum")!
        XCTAssertThrowsError(try OAuth2Client.authorizationCode(from: url, expectedState: "durum"))
    }

    // MARK: - Token istekleri

    func testExchangeRequestBody() throws {
        let request = try OAuth2Client.exchangeRequest(
            config: makeConfig(),
            code: "kod-123",
            verifier: "dogrulayici",
            redirectURI: "http://127.0.0.1:51234/callback",
            resolvedClientSecret: nil
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=kod-123"))
        XCTAssertTrue(body.contains("code_verifier=dogrulayici"))
        XCTAssertFalse(body.contains("client_secret"), "secret verilmediyse alan hiç gitmemeli")
    }

    func testExchangeIncludesClientSecretWhenProvided() throws {
        let request = try OAuth2Client.exchangeRequest(
            config: makeConfig(), code: "k", verifier: "v",
            redirectURI: "http://127.0.0.1:1/callback", resolvedClientSecret: "gizli"
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("client_secret=gizli"))
    }

    func testRefreshRequestBody() throws {
        let request = try OAuth2Client.refreshRequest(
            config: makeConfig(), refreshToken: "yenileme-123", resolvedClientSecret: nil
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=yenileme-123"))
    }

    func testPlainHTTPTokenEndpointIsRejected() {
        var config = makeConfig()
        config.tokenURL = "http://idp.example.com/token"
        // Token uç noktası kimlik bilgisi taşır; şifresiz kanal kabul edilmez.
        XCTAssertThrowsError(try OAuth2Client.refreshRequest(
            config: config, refreshToken: "x", resolvedClientSecret: nil
        ))
    }

    func testLocalhostHTTPTokenEndpointAllowed() {
        var config = makeConfig()
        config.tokenURL = "http://localhost:8080/token"
        // Yerel geliştirme IdP'leri için istisna.
        XCTAssertNoThrow(try OAuth2Client.refreshRequest(
            config: config, refreshToken: "x", resolvedClientSecret: nil
        ))
    }

    // MARK: - Token yanıtı

    func testParseTokenResponse() throws {
        let json = #"{"access_token":"at","refresh_token":"rt","token_type":"Bearer","expires_in":3600,"scope":"openid"}"#
        let now = Date()
        let token = try OAuth2Client.parseTokenResponse(Data(json.utf8), statusCode: 200, now: now)
        XCTAssertEqual(token.accessToken, "at")
        XCTAssertEqual(token.refreshToken, "rt")
        XCTAssertEqual(token.scope, "openid")
        XCTAssertEqual(token.expiresAt?.timeIntervalSince(now) ?? 0, 3600, accuracy: 1)
    }

    func testParseTokenResponseWithoutExpiry() throws {
        let json = #"{"access_token":"at"}"#
        let token = try OAuth2Client.parseTokenResponse(Data(json.utf8), statusCode: 200)
        XCTAssertNil(token.expiresAt)
        XCTAssertFalse(token.isExpired())
        XCTAssertEqual(token.tokenType, "Bearer")
    }

    func testProviderErrorResponseIsSurfaced() {
        let json = #"{"error":"invalid_grant","error_description":"Kod süresi doldu"}"#
        XCTAssertThrowsError(try OAuth2Client.parseTokenResponse(Data(json.utf8), statusCode: 400)) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid_grant"))
            XCTAssertTrue(error.localizedDescription.contains("Kod süresi doldu"))
        }
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try OAuth2Client.parseTokenResponse(Data("bozuk".utf8), statusCode: 200))
    }
}

final class OAuth2TokenTests: XCTestCase {
    func testExpiryLeewayTreatsNearExpiryAsExpired() {
        let now = Date()
        let token = OAuth2Token(accessToken: "at", expiresAt: now.addingTimeInterval(10))
        // 10 saniye kaldı ama 30 saniyelik pay var: süresi dolmuş sayılır.
        XCTAssertTrue(token.isExpired(now: now))
    }

    func testComfortablyValidTokenIsNotExpired() {
        let now = Date()
        let token = OAuth2Token(accessToken: "at", expiresAt: now.addingTimeInterval(600))
        XCTAssertFalse(token.isExpired(now: now))
    }

    func testTokenWithoutExpiryNeverExpires() {
        XCTAssertFalse(OAuth2Token(accessToken: "at").isExpired())
    }

    func testAuthorizationHeaderValue() {
        XCTAssertEqual(OAuth2Token(accessToken: "abc").authorizationHeaderValue, "Bearer abc")
        XCTAssertEqual(
            OAuth2Token(accessToken: "abc", tokenType: "DPoP").authorizationHeaderValue,
            "DPoP abc"
        )
    }

    func testTokenSecretNameIsStablePerConfig() {
        let config = OAuth2Config()
        XCTAssertEqual(config.tokenSecretName, "oauth2.\(config.id.uuidString)")
    }
}

final class LoopbackReceiverTests: XCTestCase {
    func testBindsToLoopbackAndReportsPort() throws {
        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }
        XCTAssertGreaterThan(receiver.port, 0)
        // Yalnızca 127.0.0.1 — tüm arayüzlere açılsaydı yerel ağdaki başka
        // bir makine yetkilendirme kodunu yakalayabilirdi.
        XCTAssertTrue(receiver.redirectURI.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(receiver.redirectURI.hasSuffix("/callback"))
    }

    func testReceivesCallbackQuery() async throws {
        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }

        Task {
            try? await Task.sleep(for: .milliseconds(150))
            let url = URL(string: "\(receiver.redirectURI)?code=kod-abc&state=durum-xyz")!
            _ = try? await URLSession(configuration: .ephemeral).data(from: url)
        }

        let callback = try await receiver.waitForCallback(timeout: 10)
        let code = try OAuth2Client.authorizationCode(from: callback, expectedState: "durum-xyz")
        XCTAssertEqual(code, "kod-abc")
    }
}
