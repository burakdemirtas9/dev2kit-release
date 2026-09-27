import XCTest
@testable import Dev2KitCore

final class AuthKindTests: XCTestCase {
    func testKindMatchesCase() {
        XCTAssertEqual(AuthConfig.none.kind, .none)
        XCTAssertEqual(AuthConfig.basic(username: "a", password: "b").kind, .basic)
        XCTAssertEqual(AuthConfig.bearer(token: "t").kind, .bearer)
        XCTAssertEqual(AuthConfig.apiKey(key: "k", value: "v", location: .header).kind, .apiKey)
        XCTAssertEqual(AuthConfig.oauth2(OAuth2Config()).kind, .oauth2)
    }

    func testEmptyProducesMatchingKind() {
        for kind in AuthKind.allCases {
            XCTAssertEqual(AuthConfig.empty(kind).kind, kind, "\(kind) boş hali kendi türünü vermeliydi")
        }
    }

    func testAPIKeyDefaultsToHeaderNamedXApiKey() {
        guard case .apiKey(let key, let value, let location) = AuthConfig.empty(.apiKey) else {
            return XCTFail("apiKey bekleniyordu")
        }
        XCTAssertEqual(key, "X-Api-Key")
        XCTAssertEqual(value, "")
        XCTAssertEqual(location, .header)
    }

    func testEmptyCarriesNoSecret() {
        // Boş hal asla önceki sırrı taşımamalı.
        XCTAssertEqual(AuthConfig.empty(.bearer), .bearer(token: ""))
        XCTAssertEqual(AuthConfig.empty(.basic), .basic(username: "", password: ""))
    }
}
