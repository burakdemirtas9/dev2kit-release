import XCTest
@testable import Dev2KitCore

final class TokenVariableTests: XCTestCase {
    private let token = TokenVariable(
        name: "accessToken",
        tokenURL: "https://auth.ornek.com/oauth/token",
        clientID: "istemci",
        clientSecret: "{{secret:cc_secret}}"
    )

    private func environment(variables: [String: String] = [:]) -> EnvironmentModel {
        EnvironmentModel(
            name: "test",
            variables: variables.map { KeyValueEntry(key: $0.key, value: $0.value) },
            tokenVariables: [token]
        )
    }

    // MARK: - Hangi istek token kullanıyor

    func testDirectReferenceIsFound() {
        let request = RequestModel(url: "https://api.ornek.com", headers: [KeyValueEntry(key: "Authorization", value: "Bearer {{accessToken}}")])
        XCTAssertEqual(TokenVariables.referenced(by: request, environment: environment()).map(\.name), ["accessToken"])
    }

    func testReferenceThroughAnotherVariableIsFound() {
        let request = RequestModel(url: "https://api.ornek.com", auth: .bearer(token: "{{auth}}"))
        let env = environment(variables: ["auth": "{{accessToken}}"])
        XCTAssertEqual(TokenVariables.referenced(by: request, environment: env).map(\.name), ["accessToken"])
    }

    func testUnrelatedOrDisabledUseDoesNotTriggerAFetch() {
        let unrelated = RequestModel(url: "https://api.ornek.com/{{accessTokenX}}")
        XCTAssertTrue(TokenVariables.referenced(by: unrelated, environment: environment()).isEmpty)
        let disabled = RequestModel(
            url: "https://api.ornek.com",
            headers: [KeyValueEntry(key: "Authorization", value: "Bearer {{accessToken}}", enabled: false)]
        )
        XCTAssertTrue(TokenVariables.referenced(by: disabled, environment: environment()).isEmpty)
    }

    // MARK: - Gönderim

    func testTokenResolvesFromMemoryAndWinsOverSameNamedVariable() throws {
        let env = TokenVariables.environmentForSend(environment(variables: ["accessToken": "eski-duz-deger"]))
        XCTAssertEqual(env.variables.filter { $0.key == "accessToken" }.map(\.value), ["{{secret:oauth2-token/accessToken}}"])

        let store = OverlaySecretStore(base: InMemorySecretStore(), overrides: [token.secretName: "taze-token"])
        let request = RequestModel(url: "https://api.ornek.com", headers: [KeyValueEntry(key: "Authorization", value: "Bearer {{accessToken}}")])
        let built = try RequestEngine().buildURLRequest(request, resolver: VariableResolver(environment: env, secretStore: store))
        XCTAssertEqual(built.value(forHTTPHeaderField: "Authorization"), "Bearer taze-token")
    }

    func testTokenIsTreatedAsASecretBySecurityChecks() throws {
        let env = TokenVariables.environmentForSend(environment())
        let store = OverlaySecretStore(base: InMemorySecretStore(), overrides: [token.secretName: "taze-token"])
        let request = RequestModel(url: "http://api.ornek.com", headers: [KeyValueEntry(key: "Authorization", value: "Bearer {{accessToken}}")])
        let built = try RequestEngine().buildURLRequest(request, resolver: VariableResolver(environment: env, secretStore: store))
        let findings = RequestInspector.inspect(model: request, request: built, environment: env, policy: .notConfigured)
        XCTAssertTrue(findings.contains { $0.title == "Kimlik bilgisi şifresiz gidiyor" })
        XCTAssertTrue(findings.contains { $0.approvalKey == "secret-host|oauth2-token/accessToken|api.ornek.com" })
    }

    func testOverlayNeverWritesTheTokenToTheVault() throws {
        let base = InMemorySecretStore(initial: ["kalici": "1"])
        let overlay = OverlaySecretStore(base: base, overrides: ["gecici": "token"])
        XCTAssertEqual(try overlay.secret(forName: "gecici"), "token")
        XCTAssertEqual(try overlay.secret(forName: "kalici"), "1")
        XCTAssertNil(try base.secret(forName: "gecici"))
        XCTAssertEqual(try overlay.listSecretNames(), ["kalici"])
    }

    // MARK: - Token isteği

    func testBasicHeaderAuthentication() throws {
        let request = try OAuth2Client.clientCredentialsRequest(
            tokenURL: "https://auth.ornek.com/token",
            clientID: "istemci id",
            clientSecret: "gizli:değer",
            scope: "okuma yazma",
            authentication: .basicHeader
        )
        XCTAssertEqual(request.httpMethod, "POST")
        let header = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        let decoded = String(decoding: try XCTUnwrap(Data(base64Encoded: String(header.dropFirst("Basic ".count)))), as: UTF8.self)
        XCTAssertEqual(decoded, "istemci+id:gizli%3Ade%C4%9Fer")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=client_credentials"))
        XCTAssertTrue(body.contains("scope=okuma%20yazma"))
        XCTAssertFalse(body.contains("client_secret"), "secret gövdeye de yazılmamalı")
    }

    func testRequestBodyAuthentication() throws {
        let request = try OAuth2Client.clientCredentialsRequest(
            tokenURL: "https://auth.ornek.com/token",
            clientID: "istemci",
            clientSecret: "gizli",
            scope: "",
            authentication: .requestBody
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body, "client_id=istemci&client_secret=gizli&grant_type=client_credentials")
    }

    func testCleartextTokenEndpointIsRejected() {
        XCTAssertThrowsError(try OAuth2Client.clientCredentialsRequest(
            tokenURL: "http://auth.ornek.com/token", clientID: "a", clientSecret: "b", scope: "", authentication: .basicHeader
        ))
        XCTAssertNoThrow(try OAuth2Client.clientCredentialsRequest(
            tokenURL: "http://localhost:8080/token", clientID: "a", clientSecret: "b", scope: "", authentication: .basicHeader
        ))
    }

    func testEmptyClientIDIsRejected() {
        XCTAssertThrowsError(try OAuth2Client.clientCredentialsRequest(
            tokenURL: "https://auth.ornek.com/token", clientID: " ", clientSecret: "b", scope: "", authentication: .basicHeader
        ))
    }

    // MARK: - Kalıcılık

    func testOldEnvironmentFilesDecodeWithoutTokenVariables() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"test","variables":[]}"#
        let env = try JSONDecoder().decode(EnvironmentModel.self, from: Data(json.utf8))
        XCTAssertTrue(env.tokenVariables.isEmpty)
    }

    func testTokenVariableRoundTripsWithoutAnyTokenValue() throws {
        let data = try JSONEncoder().encode(environment())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("cc_secret"))
        XCTAssertEqual(try JSONDecoder().decode(EnvironmentModel.self, from: data).tokenVariables, [token])
    }
}
