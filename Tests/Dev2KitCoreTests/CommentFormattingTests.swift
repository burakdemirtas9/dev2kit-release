import XCTest
@testable import Dev2KitCore

/// Yorumlu içerik: normal beautifier'lar gibi biçimlendirilir, hata vermez;
/// yorumlar yerinde korunur.
final class CommentFormattingTests: XCTestCase {
    /// Beklenen mesajlar Türkçe.
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    // MARK: - JSON (JSONC)

    func testJSONWithLineCommentsIsBeautified() throws {
        let result = try JSONFormatter.beautify("{\n// baş\n\"a\":1, // a'nın açıklaması\n\"b\":2}")
        XCTAssertEqual(result, """
        {
          // baş
          "a": 1, // a'nın açıklaması
          "b": 2
        }
        """)
    }

    func testJSONWithBlockCommentsIsBeautified() throws {
        let result = try JSONFormatter.beautify(#"{ /* satır içi */ "a": [1, 2] /* son */ }"#)
        // Kaynakta `{` ile aynı satırdaki yorum orada kalır.
        XCTAssertEqual(result, """
        { /* satır içi */
          "a": [
            1,
            2
          ] /* son */
        }
        """)
    }

    func testJSONTrailingCommentOnLastItemKeepsClosingBraceOnNextLine() throws {
        let result = try JSONFormatter.beautify("{\"a\":1 // son\n}")
        XCTAssertEqual(result, "{\n  \"a\": 1 // son\n}")
    }

    func testJSONCommentAfterOpeningBrace() throws {
        XCTAssertEqual(try JSONFormatter.beautify("{ // açıklama\n\"a\":1}"), "{ // açıklama\n  \"a\": 1\n}")
        XCTAssertEqual(try JSONFormatter.beautify("{ // yalnızca yorum\n}"), "{ // yalnızca yorum\n}")
    }

    func testJSONLeadingCommentBeforeDocument() throws {
        let result = try JSONFormatter.beautify("// örnek istek\n{\"a\":1}")
        XCTAssertEqual(result, "// örnek istek\n{\n  \"a\": 1\n}")
    }

    func testSlashesInsideJSONStringsAreNotComments() throws {
        let result = try JSONFormatter.beautify(#"{"url":"http://x/*y*/","p":"a//b"}"#)
        XCTAssertTrue(result.contains(#""url": "http://x/*y*/""#))
        XCTAssertTrue(result.contains(#""p": "a//b""#))
    }

    func testInvalidJSONWithCommentsStillThrows() {
        XCTAssertThrowsError(try JSONFormatter.beautify("{ // yorum\n\"a\": }"))
        XCTAssertThrowsError(try JSONFormatter.beautify("{ /* kapanmamış \"a\": 1 }"))
        XCTAssertThrowsError(try JSONFormatter.beautify("// yalnızca yorum")) { error in
            XCTAssertEqual(error.localizedDescription, "Geçersiz JSON: yorumlardan başka içerik yok")
        }
    }

    func testJSONErrorLineNumbersMatchTheOriginalText() throws {
        // Yorumlar boşlukla ayıklanır, satırlar yerinde kalır: hata satırı
        // kullanıcının gördüğü metindeki satırdır.
        XCTAssertThrowsError(try JSONFormatter.beautify("{\n/* bir\niki */\n\"a\": }")) { error in
            XCTAssertTrue(error.localizedDescription.contains("line 4"), error.localizedDescription)
        }
    }

    func testCommentedJSONIsDetectedAsJSON() {
        XCTAssertEqual(Beautifier.kind(contentType: "", body: "// not\n{\"a\":1}"), .json)
        XCTAssertEqual(Beautifier.kind(contentType: "", body: "/* not */ [1]"), .json)
    }

    // MARK: - JavaScript

    func testJSTrailingCommentStaysOnItsLine() throws {
        let result = try ScriptFormatter.beautify("const a = {b: 1, // yorum\n c: 2};\nfoo(a); // sonda")
        XCTAssertEqual(result, """
        const a = {
          b: 1, // yorum
          c: 2
        };
        foo(a); // sonda
        """)
    }

    func testJSOwnLineCommentStaysOnOwnLine() throws {
        let result = try ScriptFormatter.beautify("function f() {\n// açıklama\nreturn 1;\n}")
        XCTAssertEqual(result, "function f() {\n  // açıklama\n  return 1;\n}")
    }

    func testJSCodeAfterLineCommentNeverJoinsTheComment() throws {
        // `return x // c` sonrası `}` aynı satıra yazılsaydı yorumun içine girerdi.
        let result = try ScriptFormatter.beautify("function f() {\n  return x // c\n}")
        XCTAssertEqual(result, "function f() {\n  return x // c\n}")
    }

    func testJSCommentDoesNotTurnDivisionIntoRegex() throws {
        // Yorum "son anlamlı karakter" sayılmaz: sonraki `/` yine doğru yorumlanır.
        let result = try ScriptFormatter.beautify("let r = a / b; // bölme\nlet s = /x/g;")
        XCTAssertTrue(result.contains("a / b; // bölme"), result)
        XCTAssertTrue(result.contains("/x/g"), result)
    }

    // MARK: - XML / HTML

    func testMarkupCommentsAreKept() throws {
        XCTAssertEqual(
            try MarkupFormatter.beautify("<a><!-- <b> --><c/></a>", flavor: .xml),
            "<a>\n  <!-- <b> -->\n  <c/>\n</a>"
        )
        XCTAssertThrowsError(try MarkupFormatter.beautify("<a><!-- kapanmamış</a>", flavor: .xml))
    }

    // MARK: - Ortak parçalar

    func testStrippingCommentsKeepsStringsAndLineBreaks() {
        XCTAssertEqual(
            CodeScanner.strippingComments("\"//x\" // y\n/*a\nb*/1"),
            "\"//x\"     \n   \n   1"
        )
    }

    func testStrippingCommentsLeavesUnclosedInputForTheValidator() {
        XCTAssertEqual(CodeScanner.strippingComments("1 /* açık"), "1 /* açık")
        XCTAssertEqual(CodeScanner.strippingComments("\"açık // değil"), "\"açık // değil")
    }

    func testReadQuotedRespectsEscapesAndLineBreaks() {
        var scanner = CodeScanner(#""a\"b" sonra"#)
        XCTAssertEqual(scanner.readQuoted(multiline: false), #""a\"b""#)
        XCTAssertEqual(scanner.current, " ")

        var single = CodeScanner("'a\nb'")
        XCTAssertNil(single.readQuoted(multiline: false))
        XCTAssertEqual(single.index, 0, "kapanmamışsa konum değişmemeli")
        var template = CodeScanner("`a\nb`")
        XCTAssertEqual(template.readQuoted(multiline: true), "`a\nb`")
    }

    func testCommentIsTrailingOnlyWhenCodePrecedesItOnTheLine() throws {
        var trailing = CodeScanner("x; // c")
        trailing.index = 3
        XCTAssertEqual(try trailing.readComment(language: "JS")?.isTrailing, true)

        var ownLine = CodeScanner("x;\n   // c")
        ownLine.index = 6
        XCTAssertEqual(try ownLine.readComment(language: "JS")?.isTrailing, false)
    }

    func testAllFormattersShareTheErrorType() {
        for kind in [Beautifier.Kind.json, .xml, .html, .javascript] {
            XCTAssertThrowsError(try Beautifier.beautify("   ", as: kind)) { error in
                XCTAssertTrue(error is BeautifyError, "\(kind)")
                XCTAssertTrue(error.localizedDescription.hasSuffix("içerik boş"), "\(kind)")
            }
        }
    }
}
