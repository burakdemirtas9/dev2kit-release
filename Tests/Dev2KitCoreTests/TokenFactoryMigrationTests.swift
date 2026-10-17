import Foundation
import XCTest
@testable import Dev2KitCore

/// Eski environment "token değişkenleri" → Token Factory istekleri.
final class TokenFactoryMigrationTests: XCTestCase {
    private func workspace(_ environments: [EnvironmentModel]) -> WorkspaceModel {
        WorkspaceModel(collections: [CollectionModel(name: "API")], environments: environments)
    }

    private func legacy(
        name: String = "accessToken",
        scope: String = "",
        authentication: TokenVariable.ClientAuthentication = .basicHeader
    ) -> TokenVariable {
        TokenVariable(
            name: name,
            tokenURL: "{{authUrl}}/token",
            clientID: "istemci",
            clientSecret: "{{secret:cc_secret}}",
            scope: scope,
            clientAuthentication: authentication
        )
    }

    func testNothingToMigrateLeavesWorkspaceUntouched() {
        var model = workspace([EnvironmentModel(name: "Dev")])
        XCTAssertEqual(TokenFactoryMigration.migrate(&model), 0)
        XCTAssertFalse(model.collections.contains(where: \.isTokenFactory))
    }

    func testBasicHeaderVariableBecomesFormPostWithBasicAuth() throws {
        let env = EnvironmentModel(name: "Dev", tokenVariables: [legacy(scope: "okuma")])
        var model = workspace([env])
        XCTAssertEqual(TokenFactoryMigration.migrate(&model), 1)

        let request = try XCTUnwrap(model.tokenFactoryRequests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url, "{{authUrl}}/token")
        XCTAssertEqual(request.auth, .basic(username: "istemci", password: "{{secret:cc_secret}}"))
        guard case .formURLEncoded(let fields) = request.body else { return XCTFail("form gövdesi bekleniyordu") }
        XCTAssertEqual(fields.map(\.key), ["grant_type", "scope"])
        XCTAssertEqual(fields.map(\.value), ["client_credentials", "okuma"])
        XCTAssertEqual(request.tokenOutput, TokenOutput(responseField: "access_token", variableName: "accessToken", environmentID: env.id))
    }

    func testBodyAuthenticationPutsClientInForm() throws {
        var model = workspace([EnvironmentModel(name: "Dev", tokenVariables: [legacy(authentication: .requestBody)])])
        TokenFactoryMigration.migrate(&model)
        let request = try XCTUnwrap(model.tokenFactoryRequests.first)
        XCTAssertEqual(request.auth, AuthConfig.none)
        guard case .formURLEncoded(let fields) = request.body else { return XCTFail() }
        XCTAssertEqual(fields.map(\.key), ["grant_type", "client_id", "client_secret"])
        // Secret referansı çözülmeden taşınır; diske düz değer yazılmaz.
        XCTAssertEqual(fields.last?.value, "{{secret:cc_secret}}")
    }

    func testEachEnvironmentKeepsItsOwnTokenService() {
        let dev = EnvironmentModel(name: "Dev", tokenVariables: [legacy()])
        let prod = EnvironmentModel(name: "Prod", tokenVariables: [legacy()])
        var model = workspace([dev, prod])
        XCTAssertEqual(TokenFactoryMigration.migrate(&model), 2)

        let requests = model.tokenFactoryRequests
        XCTAssertEqual(requests.map(\.name), ["accessToken (Dev)", "accessToken (Prod)"])
        // Aynı değişken adı, ayrı environment: çakışma değil.
        XCTAssertTrue(TokenFactory.problems(in: requests, environment: dev).isEmpty)
        XCTAssertEqual(TokenFactory.sources(in: requests, environment: prod).map(\.request.name), ["accessToken (Prod)"])
    }

    func testLegacyVariablesAreRemovedAndMigrationRunsOnce() {
        var model = workspace([EnvironmentModel(name: "Dev", tokenVariables: [legacy()])])
        TokenFactoryMigration.migrate(&model)
        XCTAssertTrue(model.environments.allSatisfy { $0.tokenVariables.isEmpty })
        XCTAssertEqual(TokenFactoryMigration.migrate(&model), 0)
        XCTAssertEqual(model.collections.filter(\.isTokenFactory).count, 1)
        XCTAssertEqual(model.tokenFactoryRequests.count, 1)
    }

    func testExistingRequestsKeepWorkingWithSameVariableName() {
        // `{{accessToken}}` kullanan istek taşımadan sonra da aynı token'ı bulmalı.
        let env = EnvironmentModel(name: "Dev", tokenVariables: [legacy()])
        var model = workspace([env])
        TokenFactoryMigration.migrate(&model)
        let request = RequestModel(url: "https://api", auth: .bearer(token: "{{accessToken}}"))
        let sources = TokenFactory.sources(in: model.tokenFactoryRequests, environment: model.environments[0])
        XCTAssertEqual(
            TokenFactory.referenced(by: request, environment: model.environments[0], sources: sources).map(\.variable),
            ["accessToken"]
        )
    }
}

/// Token Factory kabı ve istekteki ayar: kalıcılık ve geriye uyumluluk.
final class TokenFactoryModelTests: XCTestCase {
    func testFactoryIsNotARegularCollection() {
        var model = WorkspaceModel(collections: [CollectionModel(name: "API")])
        _ = model.ensureUngroupedCollection()
        _ = model.ensureTokenFactoryCollection()
        XCTAssertEqual(model.regularCollections.map(\.name), ["API"])
    }

    func testEnsureTokenFactoryIsIdempotentAndAppendsAtEnd() {
        var model = WorkspaceModel(collections: [CollectionModel(name: "API")])
        let first = model.ensureTokenFactoryCollection()
        XCTAssertEqual(model.ensureTokenFactoryCollection(), first)
        XCTAssertEqual(model.collections.last?.isTokenFactory, true)
        XCTAssertEqual(model.collections.count, 2)
    }

    func testLegacyFilesDecodeWithoutNewFields() throws {
        let legacyCollection = #"{"id":"\#(UUID().uuidString)","name":"API","requests":[]}"#
        XCTAssertFalse(try JSONDecoder().decode(CollectionModel.self, from: Data(legacyCollection.utf8)).isTokenFactory)

        let legacyRequest = #"{"id":"\#(UUID().uuidString)","name":"r","method":"GET","url":"https://a"}"#
        XCTAssertNil(try JSONDecoder().decode(RequestModel.self, from: Data(legacyRequest.utf8)).tokenOutput)
    }

    func testTokenOutputRoundTripsAndPartialFillsDefaults() throws {
        var request = RequestModel(name: "login", tokenOutput: TokenOutput(responseField: "data.jwt", variableName: "jwt"))
        let decoded = try JSONDecoder().decode(RequestModel.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.tokenOutput, request.tokenOutput)

        request.tokenOutput = nil
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(encoded.contains("tokenOutput"), "normal isteklerin dosyası değişmemeli")

        let partial = try JSONDecoder().decode(TokenOutput.self, from: Data(#"{"variableName":"jwt"}"#.utf8))
        XCTAssertEqual(partial, TokenOutput(responseField: "access_token", variableName: "jwt"))
    }

    func testTokenOutputIsNotAFunctionalChange() {
        // "Son gönderilenden farklı" işareti tele çıkan şeye bakar.
        let base = RequestModel(name: "login", method: .post, url: "https://auth")
        var changed = base
        changed.tokenOutput = TokenOutput(variableName: "baska")
        XCTAssertTrue(changed.isFunctionallyEqual(to: base))
    }
}
