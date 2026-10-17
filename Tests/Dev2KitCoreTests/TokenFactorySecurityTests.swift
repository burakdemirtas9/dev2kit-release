import Foundation
import XCTest
@testable import Dev2KitCore

/// Token Factory token'ının gönderimde nasıl göründüğü: değer bellekten gelir,
/// güvenlik kontrolleri onu SECRET olarak görür ve hiçbir yere yazılmaz.
///
/// Bu garantiler eski "token değişkenleri" için de vardı; Token Factory'ye
/// taşınırken kaybolmasın diye aynı testler burada.
final class TokenFactorySecurityTests: XCTestCase {
    private let sources = TokenFactory.sources(
        in: [RequestModel(name: "login", tokenOutput: TokenOutput(variableName: "accessToken"))],
        environment: nil
    )

    private func send(_ request: RequestModel, environment: EnvironmentModel?) throws -> (URLRequest, EnvironmentModel?) {
        let env = TokenFactory.environmentForSend(environment, sources: sources)
        let store = OverlaySecretStore(base: InMemorySecretStore(), overrides: [sources[0].secretName: "taze-token"])
        let built = try RequestEngine().buildURLRequest(request, resolver: VariableResolver(environment: env, secretStore: store))
        return (built, env)
    }

    func testTokenResolvesFromMemoryAndWinsOverSameNamedVariable() throws {
        let env = EnvironmentModel(name: "e", variables: [KeyValueEntry(key: "accessToken", value: "eski-duz-deger")])
        let request = RequestModel(url: "https://api.ornek.com", headers: [KeyValueEntry(key: "Authorization", value: "Bearer {{accessToken}}")])
        let (built, _) = try send(request, environment: env)
        XCTAssertEqual(built.value(forHTTPHeaderField: "Authorization"), "Bearer taze-token")
    }

    func testTokenIsTreatedAsASecretBySecurityChecks() throws {
        // Şifresiz http uyarısı ve "secret yeni host'a gidiyor" onayı token için de geçerli.
        let request = RequestModel(url: "http://api.ornek.com", headers: [KeyValueEntry(key: "Authorization", value: "Bearer {{accessToken}}")])
        let (built, env) = try send(request, environment: nil)
        let findings = RequestInspector.inspect(model: request, request: built, environment: env, policy: .notConfigured)
        XCTAssertTrue(findings.contains { $0.title == "Kimlik bilgisi şifresiz gidiyor" }, "\(findings.map(\.title))")
        XCTAssertTrue(findings.contains { $0.approvalKey == "secret-host|token-factory/accessToken|api.ornek.com" })
    }

    func testOverlayNeverWritesTheTokenToTheVault() throws {
        let base = InMemorySecretStore(initial: ["kalici": "1"])
        let overlay = OverlaySecretStore(base: base, overrides: ["gecici": "token"])
        XCTAssertEqual(try overlay.secret(forName: "gecici"), "token")
        XCTAssertEqual(try overlay.secret(forName: "kalici"), "1")
        XCTAssertNil(try base.secret(forName: "gecici"))
        XCTAssertEqual(try overlay.listSecretNames(), ["kalici"])
    }

    func testTokenValueNeverReachesTheRequestModel() throws {
        // Diske yazılan model şablon olarak kalır; çözülmüş token içermez.
        let request = RequestModel(url: "https://api.ornek.com", headers: [KeyValueEntry(key: "Authorization", value: "Bearer {{accessToken}}")])
        _ = try send(request, environment: nil)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains("taze-token"))
    }
}

/// Eski biçim: environment içindeki "token değişkenleri" yalnızca taşıma için
/// okunur. Okunamazsa taşıma da yapılamaz.
final class LegacyTokenVariableDecodingTests: XCTestCase {
    func testOldEnvironmentFilesDecodeWithoutTokenVariables() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"test","variables":[]}"#
        XCTAssertTrue(try JSONDecoder().decode(EnvironmentModel.self, from: Data(json.utf8)).tokenVariables.isEmpty)
    }

    func testLegacyTokenVariableIsRead() throws {
        let json = #"""
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"test","variables":[],
         "tokenVariables":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","name":"accessToken",
           "tokenURL":"https://auth/token","clientID":"c","clientSecret":"{{secret:s}}","scope":"",
           "clientAuthentication":"requestBody"}]}
        """#
        let env = try JSONDecoder().decode(EnvironmentModel.self, from: Data(json.utf8))
        XCTAssertEqual(env.tokenVariables.map(\.name), ["accessToken"])
        XCTAssertEqual(env.tokenVariables.first?.clientAuthentication, .requestBody)
    }
}
