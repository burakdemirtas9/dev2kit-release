import XCTest
@testable import Dev2KitCore

/// Workbench JSONPath aracı: çıktı, özet, hata ayrımı ve katalogdaki yeri.
final class JSONPathToolTests: XCTestCase {
    private let tool = WorkbenchTools.jsonPath

    private func run(_ input: String, query: String) throws -> WorkbenchRunResult {
        try tool.actions[0].perform(input, options: WorkbenchOptions(query: query))
    }

    func testLivesUnderOthersOnce() {
        XCTAssertEqual(tool.category, .others)
        XCTAssertEqual(WorkbenchTool.Category.others.title, "Others")
        XCTAssertEqual(WorkbenchTool.Category.allCases.filter { $0.title == "Others" }.count, 1)
        XCTAssertEqual(WorkbenchCatalog.all.filter { $0.id == "jsonpath" }.count, 1)
        XCTAssertEqual(WorkbenchCatalog.matching("jsonpath").map(\.id), ["jsonpath"])
        XCTAssertFalse(tool.allowsOutputEditing)
    }

    func testResultsAreFormattedJSONWithMatchCount() throws {
        let result = try run(#"{"a":[{"b":1},{"b":2}]}"#, query: "$.a[*].b")
        XCTAssertEqual(result.output, "[\n  1,\n  2\n]")
        XCTAssertEqual(result.summary, "2 matches")
        XCTAssertEqual(try run(#"{"a":{"b":{"c":true}}}"#, query: "$.a").output, "[\n  {\n    \"b\": {\n      \"c\": true\n    }\n  }\n]")
        XCTAssertEqual(try run(#"{"a":1}"#, query: "$.a").summary, "1 match")
    }

    /// Eşleşme yok bir hata değildir: `[]` ve "No matches".
    func testNoMatchesIsNotAnError() throws {
        let result = try run(#"{"a":1}"#, query: "$.b")
        XCTAssertEqual(result.output, "[]")
        XCTAssertEqual(result.summary, "No matches")
    }

    /// Bozuk JSON: girdide konumlu hata (editör işaretler). Sorgu hatası:
    /// sütunlu, girdi konumu YOK (arayüz bunu sorgu hatası diye ayırır).
    func testInvalidJSONAndInvalidQueryAreDistinguished() {
        XCTAssertThrowsError(try run("{\"a\": }", query: "$.a")) { error in
            let issue = error as? WorkbenchIssue
            XCTAssertNotNil(issue?.offset)
            XCTAssertEqual(issue?.line, 1)
        }
        XCTAssertThrowsError(try run(#"{"a":1}"#, query: "$.a[")) { error in
            XCTAssertTrue(error is JSONPath.QueryError)
            XCTAssertTrue(error.localizedDescription.hasPrefix("Query error at column"), error.localizedDescription)
        }
    }

    func testIndentationOptionApplies() throws {
        var options = WorkbenchOptions(query: "$.a")
        options.indentation = .fourSpaces
        XCTAssertEqual(try tool.actions[0].perform(#"{"a":[1]}"#, options: options).output, "[\n    [\n        1\n    ]\n]")
    }

    func testSampleAndSampleQueryWorkTogether() throws {
        var options = WorkbenchOptions()
        tool.sampleOptions?(&options)
        let result = try tool.actions[0].perform(tool.sampleInput, options: options)
        XCTAssertEqual(result.summary, "2 matches")
        XCTAssertTrue(result.output.contains("Moby Dick"))
    }

    func testInputFormatterFormatsJSON() throws {
        XCTAssertEqual(try tool.inputFormatter?(#"{"a":1}"#, WorkbenchOptions()), "{\n  \"a\": 1\n}")
    }
}
