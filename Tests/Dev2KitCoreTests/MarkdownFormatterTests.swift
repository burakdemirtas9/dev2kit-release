import XCTest
@testable import Dev2KitCore

final class MarkdownFormatterTests: XCTestCase {
    /// Beklenen mesajlar Türkçe.
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    func testAlignsTablesKeepingAlignment() throws {
        let result = try MarkdownFormatter.beautify("|Ad|Tutar|Not|\n|:--|--:|:-:|\n|Ali|12|x|\n|Ayşegül|1500|yy|")
        XCTAssertEqual(result, """
        | Ad      | Tutar | Not |
        | :------ | ----: | :-: |
        | Ali     |    12 |  x  |
        | Ayşegül |  1500 | yy  |
        """)
    }

    func testCodeBlocksAreUntouched() throws {
        let input = "Metin\n```swift\nlet  a = 1   \n*  liste değil\n```\nSon"
        XCTAssertEqual(try MarkdownFormatter.beautify(input), input)
    }

    func testHeadingsListsAndBlankLines() throws {
        let result = try MarkdownFormatter.beautify("##   Başlık\nmetin\n\n\n\n* a\n+ b\n  * iç\n* * *\n#etiket değil")
        XCTAssertEqual(result, "## Başlık\n\nmetin\n\n- a\n- b\n  - iç\n* * *\n#etiket değil")
    }

    func testHardLineBreaksAreKept() throws {
        XCTAssertEqual(try MarkdownFormatter.beautify("satır bir   \nsatır iki\t\n"), "satır bir  \nsatır iki")
    }

    func testPipesInsideCodeOrEscapedDoNotSplitCells() {
        XCTAssertEqual(MarkdownFormatter.cells("| `a|b` | c\\|d | e |"), ["`a|b`", "c\\|d", "e"])
    }

    func testCheckFindsUnclosedFenceAndBrokenTables() throws {
        XCTAssertEqual(MarkdownFormatter.check("# a\n```\nb\n```"), .structurallyValid)
        guard case .invalid(let fence) = MarkdownFormatter.check("a\n\n```js\nkod") else { return XCTFail() }
        XCTAssertEqual(fence.line, 3)
        XCTAssertTrue(fence.message.contains("kapatılmamış"))
        guard case .invalid(let table) = MarkdownFormatter.check("| a | b |\n| - | - |\n| 1 | 2 | 3 |") else { return XCTFail() }
        XCTAssertEqual(table.line, 3)
    }
}

final class SQLStructureTests: XCTestCase {
    func testSQLQuotingAndComments() {
        XCTAssertEqual(StructureCheck.validate("select 'it''s', 'C:\\' -- ) yorum\nfrom t where a in (1, 2)", rules: .sql), .structurallyValid)
        guard case .invalid(let issue) = StructureCheck.validate("select (a from t", rules: .sql) else { return XCTFail() }
        XCTAssertEqual(issue.column, 8)
        guard case .invalid = StructureCheck.validate("select 'açık", rules: .sql) else { return XCTFail() }
    }

    func testSQLAndMarkdownTools() throws {
        XCTAssertEqual(WorkbenchTools.sql.actions.map(\.id), ["format", "minify"])
        XCTAssertEqual(WorkbenchTools.markdown.actions.map(\.id), ["format"], "Markdown'da sıkıştırma yok")
        XCTAssertTrue(WorkbenchTools.sql.action(id: "format").usesKeywordCase)
        XCTAssertFalse(WorkbenchTools.markdown.action(id: "format").usesIndentation)
        let lower = try WorkbenchTools.sql.action(id: "format").run("select a from t", WorkbenchOptions(uppercaseKeywords: false))
        XCTAssertEqual(lower, "select\n  a\nfrom t")
        XCTAssertEqual(Beautifier.kind(contentType: "application/sql", body: ""), .sql)
        XCTAssertEqual(Beautifier.kind(contentType: "text/markdown", body: ""), .markdown)
    }
}
