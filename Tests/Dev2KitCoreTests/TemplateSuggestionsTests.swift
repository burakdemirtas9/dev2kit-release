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

    // MARK: - Klavyeyle gezinme (2026-11-01)

    func testFirstSuggestionIsHighlightedAndArrowsWrap() {
        var nav = SuggestionNavigator()
        nav.update(["a", "b", "c"], token: "")
        XCTAssertEqual(nav.selected, "a", "ilk öneri baştan vurgulu: ⏎ hemen tamamlar")
        nav.move(1)
        XCTAssertEqual(nav.selected, "b")
        nav.move(1); nav.move(1)
        XCTAssertEqual(nav.selected, "a", "aşağıda sona varınca başa sarar")
        nav.move(-1)
        XCTAssertEqual(nav.selected, "c", "yukarıda baştan sona sarar")
    }

    func testTypingResetsHighlightOnlyWhenTheListChanges() {
        var nav = SuggestionNavigator()
        nav.update(["base", "baseUrl", "token"], token: "")
        nav.move(1)
        nav.update(["base", "baseUrl", "token"], token: "")
        XCTAssertEqual(nav.selected, "baseUrl", "aynı liste: vurgu korunur")
        nav.update(["base", "baseUrl"], token: "ba")
        XCTAssertEqual(nav.selected, "base", "liste değişti: başa döner")
    }

    func testEscapeHidesUntilTheUserTypesMore() {
        var nav = SuggestionNavigator()
        nav.update(["base", "baseUrl"], token: "ba")
        XCTAssertEqual(nav.visible(for: "ba"), ["base", "baseUrl"])
        nav.dismiss(token: "ba")
        XCTAssertEqual(nav.visible(for: "ba"), [], "Esc: kapalı")
        nav.update(["baseUrl"], token: "bas")
        XCTAssertEqual(nav.visible(for: "bas"), ["baseUrl"], "yazmaya devam edince yeniden açılır")
        XCTAssertEqual(nav.visible(for: nil), [], "{{ yoksa liste yok")
    }

    func testHoverMovesHighlightAndEmptyListIsSafe() {
        var nav = SuggestionNavigator()
        nav.move(1)
        XCTAssertNil(nav.selected)
        nav.update(["a", "b"], token: "")
        nav.highlight(1)
        XCTAssertEqual(nav.selected, "b")
        nav.highlight(5)
        XCTAssertEqual(nav.selected, "b", "geçersiz satır yok sayılır")
    }
}
