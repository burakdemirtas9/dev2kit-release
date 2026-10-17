import XCTest
@testable import Dev2KitCore

final class TemplateSuggestionsTests: XCTestCase {
    private func environment() -> EnvironmentModel {
        EnvironmentModel(
            name: "test",
            variables: [
                KeyValueEntry(key: "baseUrl", value: "https://a"),
                KeyValueEntry(key: "kapali", value: "x", enabled: false),
                KeyValueEntry(key: "", value: "adsiz"),
            ]
        )
    }

    func testDisabledAndEmptyVariablesAreSkipped() {
        let options = TemplateSuggestions.options(environment: environment(), secretNames: [], tokenVariables: ["accessToken"], matching: "")
        XCTAssertEqual(options, ["baseUrl", "accessToken"])
    }

    func testSecretsComeLastWithPrefix() {
        let options = TemplateSuggestions.options(environment: environment(), secretNames: ["token"], tokenVariables: ["accessToken"], matching: "")
        XCTAssertEqual(options.last, "secret:token")
    }

    func testQueryFiltersCaseInsensitively() {
        let options = TemplateSuggestions.options(environment: environment(), secretNames: ["token"], tokenVariables: ["accessToken"], matching: "TOK")
        XCTAssertEqual(options, ["accessToken", "secret:token"])
    }

    func testTokenVariableDoesNotDuplicateEnvironmentVariable() {
        let environment = EnvironmentModel(
            name: "test",
            variables: [KeyValueEntry(key: "accessToken", value: "x")]
        )
        let options = TemplateSuggestions.options(
            environment: environment, secretNames: [], tokenVariables: ["accessToken"], matching: ""
        )
        XCTAssertEqual(options, ["accessToken"])
    }

    func testLimitIsApplied() {
        let secrets = (1...20).map { "s\($0)" }
        let options = TemplateSuggestions.options(environment: nil, secretNames: secrets, matching: "")
        XCTAssertEqual(options.count, TemplateSuggestions.limit)
    }

    func testNoEnvironmentStillOffersSecrets() {
        XCTAssertEqual(
            TemplateSuggestions.options(environment: nil, secretNames: ["a"], matching: ""),
            ["secret:a"]
        )
    }
}
