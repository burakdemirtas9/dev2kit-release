import XCTest
@testable import Dev2KitCore

final class JSONChangeTests: XCTestCase {
    private func changes(_ a: String, _ b: String) throws -> [JSONChange] {
        JSONChange.changes(try JSONDocument.parse(a), try JSONDocument.parse(b))
    }

    func testKeyOrderAndFormattingAreIgnored() throws {
        XCTAssertTrue(try changes(#"{"a":1,"b":{"c":[1,2]}}"#, "{\n  \"b\": {\"c\": [1, 2]},\n  \"a\": 1\n}").isEmpty)
    }

    func testValueChangesWithPaths() throws {
        let result = try changes(
            #"{"data":{"items":[{"token":"x"}],"eski":1},"ok":true}"#,
            #"{"data":{"items":[{"token":"y"},{"token":"z"}],"yeni":2},"ok":false}"#
        )
        XCTAssertEqual(result.map(\.path), ["data.items[0].token", "data.items[1]", "data.eski", "data.yeni", "ok"])
        XCTAssertEqual(result[0].kind, .changed(from: .string("x"), to: .string("y")))
        XCTAssertEqual(result[2].kind, .removed(.number("1")))
        XCTAssertEqual(result[3].kind, .added(.number("2")))
        // Yol Token Factory'nin okuyabileceği sözdiziminde.
        XCTAssertNoThrow(try TokenField.steps(of: result[0].path))
    }

    func testNumbersCompareByValueWithoutPrecisionLoss() throws {
        XCTAssertTrue(try changes(#"[1.0, 1e2, 12345678901234567890]"#, #"[1, 100, 12345678901234567890]"#).isEmpty)
        XCTAssertEqual(try changes(#"[12345678901234567890]"#, #"[12345678901234567891]"#).count, 1, "son hanedeki fark kaybolmamalı")
    }

    func testTypeChangeIsAChange() throws {
        let result = try changes(#"{"a":"1"}"#, #"{"a":1}"#)
        XCTAssertEqual(result.first?.kind, .changed(from: .string("1"), to: .number("1")))
    }
}

final class DiffCheckerTests: XCTestCase {
    func testNormalizedJSONHidesFormattingAndKeyOrder() {
        let result = DiffChecker.compare(#"{"b":1,"a":2}"#, "{\n  \"a\": 2,\n  \"b\": 1\n}", language: .json)
        XCTAssertTrue(result.isIdentical)
        XCTAssertEqual(result.jsonChanges, [])
    }

    func testWithoutNormalizationFormattingCounts() {
        let result = DiffChecker.compare(#"{"a":1}"#, "{\n  \"a\": 1\n}", language: .json, options: .init(normalize: false))
        XCTAssertFalse(result.rows.allSatisfy { $0.kind == .equal })
        XCTAssertEqual(result.jsonChanges, [], "anlamsal olarak aynı")
    }

    func testCountsAndChangeNavigation() {
        let result = DiffChecker.compare("a\nb\nc\nd", "a\nB\nc\nd\ne", language: .text)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.changeStarts, [1, 4])
        XCTAssertNil(result.jsonChanges)
    }

    func testInvalidSideIsComparedAsIsAndReported() {
        let result = DiffChecker.compare(#"{"a":1}"#, #"{"a":}"#, language: .json)
        XCTAssertNil(result.leftIssue)
        XCTAssertNotNil(result.rightIssue)
        XCTAssertNil(result.jsonChanges, "geçersiz tarafla anlamsal fark yapılamaz")
        XCTAssertFalse(result.isIdentical)
    }

    func testOtherLanguagesUseTheirFormatter() {
        XCTAssertTrue(DiffChecker.compare("<a><b>1</b></a>", "<a>\n  <b>1</b>\n</a>", language: .xml).isIdentical)
        XCTAssertTrue(DiffChecker.compare("select a from t", "SELECT\n  a\nFROM t", language: .sql).isIdentical)
        XCTAssertTrue(DiffChecker.compare("a{color:red}", "a {\n  color: red\n}", language: .css).isIdentical)
    }

    func testEmptySides() {
        XCTAssertTrue(DiffChecker.compare("", "", language: .json).isIdentical)
        let result = DiffChecker.compare("", "a\nb", language: .text)
        XCTAssertEqual(result.added, 2)
    }
}

final class DiffCheckerCatalogTests: XCTestCase {
    func testDiffCheckerIsFoundBySearch() {
        for query in ["", "diff", "COMPARE", "karsilastir", "fark", "checker"] {
            XCTAssertTrue(WorkbenchCatalog.diffCheckerMatches(query), query)
        }
        XCTAssertFalse(WorkbenchCatalog.diffCheckerMatches("json"))
    }
}
