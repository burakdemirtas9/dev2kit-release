import Foundation
import XCTest
@testable import Dev2KitCore

/// Test için uydurma JWT: yalnızca yük anlamlı, imza sahte.
/// Gerçek token'lar hiçbir zaman fixture olarak kullanılmaz.
private func fakeJWT(_ claims: [String: Any]) -> String {
    func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(encode(["alg": "none"])).\(encode(claims)).sahte-imza"
}

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
}

// MARK: - Yanıttaki alan

final class TokenFieldTests: XCTestCase {
    func testTopLevelField() throws {
        XCTAssertEqual(try TokenField.value(at: "access_token", in: json(["access_token": "abc"])), "abc")
    }

    func testNestedField() throws {
        let body = json(["data": ["auth": ["token": "xyz"]]])
        XCTAssertEqual(try TokenField.value(at: "data.auth.token", in: body), "xyz")
    }

    func testArrayIndex() throws {
        let body = json(["items": [["jwt": "ilk"], ["jwt": "ikinci"]]])
        XCTAssertEqual(try TokenField.value(at: "items[1].jwt", in: body), "ikinci")
    }

    func testArrayAtRoot() throws {
        XCTAssertEqual(try TokenField.value(at: "[0].token", in: json([["token": "kok"]])), "kok")
    }

    func testValueIsTrimmed() throws {
        XCTAssertEqual(try TokenField.value(at: "t", in: json(["t": "  abc\n"])), "abc")
    }

    func testMissingFieldNamesTheMissingPart() {
        // Kullanıcı neyi düzelteceğini bilmeli: yolun HANGİ parçası yok.
        let body = json(["data": ["other": 1]])
        XCTAssertThrowsError(try TokenField.value(at: "data.token.value", in: body)) { error in
            XCTAssertEqual(error as? TokenField.Failure, .missing(path: "data.token"))
        }
    }

    func testOutOfRangeIndexIsMissing() {
        XCTAssertThrowsError(try TokenField.value(at: "items[3]", in: json(["items": ["a"]]))) { error in
            XCTAssertEqual(error as? TokenField.Failure, .missing(path: "items[3]"))
        }
    }

    func testNumberIsNotAcceptedAsToken() {
        // `expires_in` gibi bir alanın yanlışlıkla seçilmesi sessizce geçmemeli.
        XCTAssertThrowsError(try TokenField.value(at: "expires_in", in: json(["expires_in": 300]))) { error in
            XCTAssertEqual(error as? TokenField.Failure, .notText(path: "expires_in"))
        }
    }

    func testNullIsNotAToken() {
        XCTAssertThrowsError(try TokenField.value(at: "access_token", in: json(["access_token": NSNull()]))) { error in
            XCTAssertEqual(error as? TokenField.Failure, .notText(path: "access_token"))
        }
    }

    func testEmptyStringIsRejected() {
        XCTAssertThrowsError(try TokenField.value(at: "t", in: json(["t": "   "]))) { error in
            XCTAssertEqual(error as? TokenField.Failure, .empty(path: "t"))
        }
    }

    func testNonJSONBody() {
        XCTAssertThrowsError(try TokenField.value(at: "t", in: Data("<html>hata</html>".utf8))) { error in
            XCTAssertEqual(error as? TokenField.Failure, .notJSON)
        }
    }

    func testInvalidPaths() {
        for path in ["", "  ", "a..b", "a[x]", "a[-1]", "a[0", "."] {
            XCTAssertThrowsError(try TokenField.value(at: path, in: json(["a": ["b"]])), "yol: \"\(path)\"")
        }
    }
}

// MARK: - Süre

final class TokenLifetimeTests: XCTestCase {
    private let receivedAt = Date(timeIntervalSince1970: 1_000_000)

    func testJWTExpiryIsRead() {
        let token = fakeJWT(["exp": 1_000_300])
        let expiry = TokenLifetime.expiry(token: token, responseBody: Data(), receivedAt: receivedAt)
        XCTAssertEqual(expiry, Date(timeIntervalSince1970: 1_000_300))
    }

    func testJWTWinsOverExpiresIn() {
        // Token'ın kendi beyanı en kesin bilgi.
        let token = fakeJWT(["exp": 1_000_100])
        let body = json(["expires_in": 9999])
        XCTAssertEqual(
            TokenLifetime.expiry(token: token, responseBody: body, receivedAt: receivedAt),
            Date(timeIntervalSince1970: 1_000_100)
        )
    }

    func testExpiresInIsUsedForOpaqueToken() {
        let body = json(["access_token": "opak", "expires_in": 300])
        XCTAssertEqual(
            TokenLifetime.expiry(token: "opak", responseBody: body, receivedAt: receivedAt),
            receivedAt.addingTimeInterval(300)
        )
    }

    func testExpiresInAsText() {
        let body = json(["expires_in": "300"])
        XCTAssertEqual(
            TokenLifetime.expiry(token: "opak", responseBody: body, receivedAt: receivedAt),
            receivedAt.addingTimeInterval(300)
        )
    }

    func testBooleanIsNotADuration() {
        XCTAssertNil(TokenLifetime.expiry(token: "opak", responseBody: json(["expires_in": true]), receivedAt: receivedAt))
    }

    func testJWTWithoutExpFallsBackToExpiresIn() {
        let token = fakeJWT(["sub": "kullanici"])
        let body = json(["expires_in": 60])
        XCTAssertEqual(
            TokenLifetime.expiry(token: token, responseBody: body, receivedAt: receivedAt),
            receivedAt.addingTimeInterval(60)
        )
    }

    func testUnknownExpiry() {
        XCTAssertNil(TokenLifetime.expiry(token: "opak", responseBody: json(["access_token": "opak"]), receivedAt: receivedAt))
    }

    func testEncryptedJWTIsNotRead() {
        // JWE beş parçalı ve yükü şifreli; okunmaya çalışılmaz.
        XCTAssertNil(TokenLifetime.jwtExpiry("a.b.c.d.e"))
    }

    func testRefreshTenSecondsBeforeExpiry() {
        let expiry = receivedAt.addingTimeInterval(100)
        XCTAssertFalse(TokenLifetime.needsRefresh(expiresAt: expiry, now: expiry.addingTimeInterval(-11)))
        XCTAssertTrue(TokenLifetime.needsRefresh(expiresAt: expiry, now: expiry.addingTimeInterval(-9)))
        XCTAssertTrue(TokenLifetime.needsRefresh(expiresAt: expiry, now: expiry.addingTimeInterval(5)))
    }

    func testUnknownExpiryNeverForcesRefresh() {
        XCTAssertFalse(TokenLifetime.needsRefresh(expiresAt: nil))
    }
}

// MARK: - Kurallar

final class TokenFactoryRuleTests: XCTestCase {
    private let dev = EnvironmentModel(name: "Dev", variables: [KeyValueEntry(key: "authUrl", value: "https://auth.dev")])
    private let prod = EnvironmentModel(name: "Prod")

    private func factoryRequest(_ name: String, output: TokenOutput? = TokenOutput(), url: String = "https://auth/token") -> RequestModel {
        RequestModel(name: name, method: .post, url: url, tokenOutput: output)
    }

    func testDefaults() {
        let output = TokenOutput()
        XCTAssertEqual(output.responseField, "access_token")
        XCTAssertEqual(output.variableName, "token")
    }

    func testRequestWithoutOutputUsesDefaults() {
        let sources = TokenFactory.sources(in: [factoryRequest("a", output: nil)], environment: nil)
        XCTAssertEqual(sources.map(\.variable), ["token"])
        XCTAssertEqual(sources.first?.output.responseField, "access_token")
    }

    func testEnvironmentScopedSourceOnlyAppliesThere() {
        let request = factoryRequest("dev", output: TokenOutput(environmentID: dev.id))
        XCTAssertEqual(TokenFactory.sources(in: [request], environment: dev).count, 1)
        XCTAssertTrue(TokenFactory.sources(in: [request], environment: prod).isEmpty)
        XCTAssertTrue(TokenFactory.sources(in: [request], environment: nil).isEmpty)
    }

    func testSameVariablePerEnvironmentIsNotADuplicate() {
        // Taşınan eski değişkenler tam olarak böyle: her environment'ın kendi
        // token servisi, aynı değişken adı.
        let requests = [
            factoryRequest("dev", output: TokenOutput(environmentID: dev.id)),
            factoryRequest("prod", output: TokenOutput(environmentID: prod.id)),
        ]
        XCTAssertEqual(TokenFactory.sources(in: requests, environment: dev).map(\.request.name), ["dev"])
        XCTAssertEqual(TokenFactory.sources(in: requests, environment: prod).map(\.request.name), ["prod"])
        XCTAssertTrue(TokenFactory.problems(in: requests, environment: dev).isEmpty)
    }

    func testDuplicateVariableFirstWinsAndIsReported() {
        let requests = [factoryRequest("birinci"), factoryRequest("ikinci")]
        XCTAssertEqual(TokenFactory.sources(in: requests, environment: nil).map(\.request.name), ["birinci"])
        XCTAssertEqual(
            TokenFactory.problems(in: requests, environment: nil),
            [.duplicateVariable(name: "token", requests: ["birinci", "ikinci"])]
        )
    }

    func testInvalidVariableNamesAreRejected() {
        for name in ["", "  ", "to ken", "secret:x", "a{b", "a}b"] {
            XCTAssertFalse(TokenFactory.isValidVariableName(name.trimmingCharacters(in: .whitespaces)), name)
        }
        for name in ["token", "access_token", "auth.token", "token-2", "jeton"] {
            XCTAssertTrue(TokenFactory.isValidVariableName(name), name)
        }
        let request = factoryRequest("x", output: TokenOutput(variableName: "to ken"))
        XCTAssertTrue(TokenFactory.sources(in: [request], environment: nil).isEmpty)
        XCTAssertEqual(
            TokenFactory.problems(in: [request], environment: nil),
            [.invalidVariableName(request: "x", name: "to ken")]
        )
    }

    func testEmptyResponseFieldIsReported() {
        let request = factoryRequest("x", output: TokenOutput(responseField: " "))
        XCTAssertEqual(TokenFactory.problems(in: [request], environment: nil), [.emptyResponseField(request: "x")])
    }

    func testFactoryRequestCannotDependOnAnotherToken() {
        let login = factoryRequest("login")
        var chained = factoryRequest("zincir", output: TokenOutput(variableName: "ikinci"))
        chained.headers = [KeyValueEntry(key: "Authorization", value: "Bearer {{token}}")]
        XCTAssertEqual(
            TokenFactory.problems(in: [login, chained], environment: nil),
            [.usesFactoryVariable(request: "zincir", variable: "token")]
        )
    }

    func testDirectReference() {
        let sources = TokenFactory.sources(in: [factoryRequest("a")], environment: nil)
        let request = RequestModel(url: "https://api", headers: [KeyValueEntry(key: "Authorization", value: "Bearer {{token}}")])
        XCTAssertEqual(TokenFactory.referenced(by: request, environment: nil, sources: sources).map(\.variable), ["token"])
    }

    func testReferenceThroughEnvironmentVariable() {
        let env = EnvironmentModel(name: "e", variables: [KeyValueEntry(key: "auth", value: "Bearer {{token}}")])
        let sources = TokenFactory.sources(in: [factoryRequest("a")], environment: env)
        let request = RequestModel(url: "https://api", headers: [KeyValueEntry(key: "Authorization", value: "{{auth}}")])
        XCTAssertEqual(TokenFactory.referenced(by: request, environment: env, sources: sources).map(\.variable), ["token"])
    }

    func testDisabledHeaderDoesNotCountAsReference() {
        let sources = TokenFactory.sources(in: [factoryRequest("a")], environment: nil)
        let request = RequestModel(
            url: "https://api",
            headers: [KeyValueEntry(key: "Authorization", value: "Bearer {{token}}", enabled: false)]
        )
        XCTAssertTrue(TokenFactory.referenced(by: request, environment: nil, sources: sources).isEmpty)
    }

    func testEnvironmentForSendBindsTokenAsSecretAndShadowsVariable() {
        let env = EnvironmentModel(name: "e", variables: [
            KeyValueEntry(key: "token", value: "elle-yazilmis"),
            KeyValueEntry(key: "baseUrl", value: "https://api"),
        ])
        let sources = TokenFactory.sources(in: [factoryRequest("a")], environment: env)
        let sendEnv = TokenFactory.environmentForSend(env, sources: sources)
        XCTAssertEqual(sendEnv?.id, env.id, "çerez kapsamı değişmemeli")
        let tokenEntries = sendEnv?.variables.filter { $0.key == "token" } ?? []
        XCTAssertEqual(tokenEntries.map(\.value), ["{{secret:token-factory/token}}"])
        XCTAssertTrue(sendEnv?.variables.contains { $0.key == "baseUrl" } ?? false)
        XCTAssertEqual(TokenFactory.shadowedVariables(in: env, sources: sources), ["token"])
    }

    func testEnvironmentForSendWithoutEnvironmentKeepsDefaultCookieScope() {
        let sources = TokenFactory.sources(in: [factoryRequest("a")], environment: nil)
        let sendEnv = TokenFactory.environmentForSend(nil, sources: sources)
        XCTAssertEqual(sendEnv?.id, TokenFactory.unboundEnvironmentID)
        XCTAssertEqual(
            RequestEngine.Scope(environmentID: sendEnv?.id),
            RequestEngine.Scope(environmentID: nil),
            "geçici environment ayrı bir çerez kavanozu açmamalı"
        )
    }

    func testEnvironmentForSendWithoutTokensIsUntouched() {
        XCTAssertNil(TokenFactory.environmentForSend(nil, sources: []))
        XCTAssertEqual(TokenFactory.environmentForSend(dev, sources: []), dev)
    }
}

// MARK: - Token servisinin yanıtı

final class TokenIssueTests: XCTestCase {
    private let receivedAt = Date(timeIntervalSince1970: 1_000_000)

    func testSuccessfulResponse() throws {
        let body = json(["access_token": "abc", "expires_in": 300, "token_type": "Bearer"])
        let token = try TokenFactory.issue(statusCode: 200, body: body, output: TokenOutput(), receivedAt: receivedAt)
        XCTAssertEqual(token, TokenFactory.IssuedToken(value: "abc", expiresAt: receivedAt.addingTimeInterval(300)))
    }

    func testCustomFieldAndCreatedStatus() throws {
        let body = json(["data": ["jwt": fakeJWT(["exp": 1_000_050])]])
        let output = TokenOutput(responseField: "data.jwt", variableName: "jwt")
        let token = try TokenFactory.issue(statusCode: 201, body: body, output: output, receivedAt: receivedAt)
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 1_000_050))
    }

    func testErrorStatusIsNotATokenEvenWithField() {
        // Bazı servisler hata gövdesinde de alanı döndürüyor.
        let body = json(["access_token": "eski", "errorMessage": "müşteri bulunamadı"])
        XCTAssertThrowsError(try TokenFactory.issue(statusCode: 400, body: body, output: TokenOutput())) { error in
            XCTAssertEqual(error as? TokenFactory.IssueFailure, .httpStatus(400, detail: "müşteri bulunamadı"))
        }
    }

    func testOAuthErrorIsDescribed() {
        let body = json(["error": "invalid_client", "error_description": "Client secret hatalı"])
        XCTAssertThrowsError(try TokenFactory.issue(statusCode: 401, body: body, output: TokenOutput())) { error in
            XCTAssertEqual(error as? TokenFactory.IssueFailure, .httpStatus(401, detail: "invalid_client — Client secret hatalı"))
            XCTAssertTrue(error.localizedDescription.contains("HTTP 401"), error.localizedDescription)
        }
    }

    func testErrorBodyIsNotEchoed() {
        // Hata gövdesi kişisel veri ya da kimlik bilgisi taşıyabilir; yalnızca
        // tanınan açıklama alanları gösterilir.
        let body = json(["client_secret": "GIZLI", "trace": "ic-ayrinti"])
        XCTAssertThrowsError(try TokenFactory.issue(statusCode: 500, body: body, output: TokenOutput())) { error in
            XCTAssertEqual(error as? TokenFactory.IssueFailure, .httpStatus(500, detail: nil))
            XCTAssertFalse(error.localizedDescription.contains("GIZLI"))
        }
    }

    func testLongDetailIsTruncated() {
        let body = json(["message": String(repeating: "x", count: 500)])
        XCTAssertThrowsError(try TokenFactory.issue(statusCode: 500, body: body, output: TokenOutput())) { error in
            guard case .httpStatus(_, let detail)? = error as? TokenFactory.IssueFailure else { return XCTFail() }
            XCTAssertEqual(detail?.count, 201)
        }
    }

    func testMissingFieldOnSuccessNamesFieldAndStatus() {
        // Sahadaki örnek yanıt "errorMessage": null ile geliyor; alan yoksa
        // kullanıcı alan adını düzeltebilmeli.
        let body = json(["accessToken": "abc", "errorMessage": NSNull()])
        XCTAssertThrowsError(try TokenFactory.issue(statusCode: 200, body: body, output: TokenOutput())) { error in
            XCTAssertEqual(error as? TokenFactory.IssueFailure, .field(.missing(path: "access_token"), statusCode: 200))
            XCTAssertTrue(error.localizedDescription.contains("access_token"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("HTTP 200"), error.localizedDescription)
        }
    }
}

// MARK: - Hata sonrası öneri

final class TokenRetryAdviceTests: XCTestCase {
    func testSuccessNeedsNoAdvice() {
        for status in [200, 201, 204] {
            XCTAssertNil(TokenRetryAdvice.advice(statusCode: status, usedVariables: ["token"], afterRefresh: false))
        }
    }

    func testRequestWithoutTokensNeedsNoAdvice() {
        XCTAssertNil(TokenRetryAdvice.advice(statusCode: 401, usedVariables: [], afterRefresh: false))
    }

    func testFirstFailureOffersRefresh() {
        // 401 dışındaki hatalarda da: bazı API'ler süresi dolmuş token'a 403 ya da 500 dönüyor.
        for status in [401, 403, 500] {
            XCTAssertEqual(
                TokenRetryAdvice.advice(statusCode: status, usedVariables: ["token"], afterRefresh: false),
                .offerRefresh(statusCode: status, variables: ["token"])
            )
        }
    }

    func testFailureAfterRefreshPointsAtTokenContent() {
        XCTAssertEqual(
            TokenRetryAdvice.advice(statusCode: 403, usedVariables: ["token"], afterRefresh: true),
            .checkTokenContent(statusCode: 403, variables: ["token"])
        )
    }

    func testSuccessAfterRefreshClearsAdvice() {
        XCTAssertNil(TokenRetryAdvice.advice(statusCode: 200, usedVariables: ["token"], afterRefresh: true))
    }

    func testVariablesAreStableOrdered() {
        XCTAssertEqual(
            TokenRetryAdvice.advice(statusCode: 401, usedVariables: ["b", "a"], afterRefresh: false)?.variables,
            ["a", "b"]
        )
    }
}

// MARK: - Token olmadan gönder

final class TokenlessSendTests: XCTestCase {
    private let sources = TokenFactory.sources(in: [RequestModel(name: "login", tokenOutput: TokenOutput(variableName: "accessToken"))], environment: nil)

    func testEnvironmentVariableIsUsedAsFallback() {
        let env = EnvironmentModel(name: "e", variables: [KeyValueEntry(key: "accessToken", value: "elle")])
        let result = TokenFactory.environmentWithoutTokens(env, sources: sources)
        XCTAssertEqual(result?.variables.filter { $0.key == "accessToken" }.map(\.value), ["elle"])
        XCTAssertEqual(result?.id, env.id)
    }

    func testMissingVariableIsBoundEmpty() throws {
        let result = TokenFactory.environmentWithoutTokens(nil, sources: sources)
        XCTAssertEqual(result?.variables.map(\.key), ["accessToken"])
        XCTAssertEqual(result?.variables.map(\.value), [""])
        XCTAssertEqual(result?.id, TokenFactory.unboundEnvironmentID, "çerez kapsamı değişmemeli")
        // Gönderimde tanımsız değişken hatası vermemeli: boş çözülür.
        let resolver = VariableResolver(environment: result, secretStore: InMemorySecretStore(initial: [:]))
        XCTAssertEqual(try resolver.resolve("Bearer {{accessToken}}"), "Bearer ")
    }

    func testDisabledVariableIsNotAFallback() {
        let env = EnvironmentModel(name: "e", variables: [KeyValueEntry(key: "accessToken", value: "eski", enabled: false)])
        let values = TokenFactory.environmentWithoutTokens(env, sources: sources)?
            .variables.filter { $0.key == "accessToken" && $0.enabled }.map(\.value)
        XCTAssertEqual(values, [""])
    }
}
