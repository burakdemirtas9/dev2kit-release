import XCTest
@testable import Dev2KitCore

final class MarkupFormatterTests: XCTestCase {
    // MARK: - XML

    func testIndentsNestedXML() throws {
        let result = try MarkupFormatter.beautify(
            "<kutuphane><kitap id=\"1\"><adi>Nutuk</adi></kitap></kutuphane>",
            flavor: .xml
        )
        XCTAssertEqual(result, """
        <kutuphane>
          <kitap id="1">
            <adi>Nutuk</adi>
          </kitap>
        </kutuphane>
        """)
    }

    func testKeepsDeclarationOnOwnLine() throws {
        let result = try MarkupFormatter.beautify(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><a><b>1</b></a>",
            flavor: .xml
        )
        XCTAssertEqual(result, """
        <?xml version="1.0" encoding="UTF-8"?>
        <a>
          <b>1</b>
        </a>
        """)
    }

    func testSelfClosingAndEmptyElements() throws {
        let result = try MarkupFormatter.beautify("<a><b/><c></c></a>", flavor: .xml)
        XCTAssertEqual(result, """
        <a>
          <b/>
          <c></c>
        </a>
        """)
    }

    func testCommentPreserved() throws {
        let result = try MarkupFormatter.beautify("<a><!-- not --><b>1</b></a>", flavor: .xml)
        XCTAssertTrue(result.contains("  <!-- not -->"))
    }

    func testGreaterThanInsideAttributeIgnored() throws {
        let result = try MarkupFormatter.beautify("<a t=\"x>y\"><b>1</b></a>", flavor: .xml)
        XCTAssertTrue(result.hasPrefix("<a t=\"x>y\">"))
        XCTAssertTrue(result.contains("  <b>1</b>"))
    }

    func testMismatchedTagThrows() {
        XCTAssertThrowsError(try MarkupFormatter.beautify("<a><b></a></b>", flavor: .xml))
    }

    func testUnclosedTagThrows() {
        XCTAssertThrowsError(try MarkupFormatter.beautify("<a><b>1</b>", flavor: .xml))
    }

    func testEmptyThrows() {
        XCTAssertThrowsError(try MarkupFormatter.beautify("   ", flavor: .xml))
    }

    func testUnterminatedCommentThrows() {
        XCTAssertThrowsError(try MarkupFormatter.beautify("<a><!-- açık</a>", flavor: .xml))
    }

    // MARK: - HTML

    func testHTMLVoidElementsDoNotNest() throws {
        let result = try MarkupFormatter.beautify(
            "<div><img src=\"a.png\"><br><p>metin</p></div>",
            flavor: .html
        )
        XCTAssertEqual(result, """
        <div>
          <img src="a.png">
          <br>
          <p>metin</p>
        </div>
        """)
    }

    func testHTMLToleratesImplicitClose() throws {
        // <li> kapatılmadan yeni <li> açılıyor; HTML'de geçerli.
        let result = try MarkupFormatter.beautify("<ul><li>bir<li>iki</ul>", flavor: .html)
        XCTAssertTrue(result.hasPrefix("<ul>"))
        XCTAssertTrue(result.contains("iki"))
    }

    func testHTMLUnclosedTagDoesNotThrow() throws {
        XCTAssertNoThrow(try MarkupFormatter.beautify("<div><p>metin", flavor: .html))
    }

    func testDoctypePreserved() throws {
        let result = try MarkupFormatter.beautify("<!DOCTYPE html><html><body>x</body></html>", flavor: .html)
        XCTAssertTrue(result.hasPrefix("<!DOCTYPE html>"))
    }
}

/// HTML'de örtük kapanışlar: `<li>bir<li>iki` geçerlidir ve ikinci madde
/// birincinin içine girintilenmemeli.
extension MarkupFormatterTests {
    private func html(_ text: String) -> String {
        (try? MarkupFormatter.beautify(text, flavor: .html)) ?? "BİÇİMLENDİRİLEMEDİ"
    }

    func testUnclosedListItemsStaySiblings() {
        // Asıl mesele girinti DERİNLİĞİ: iki madde kardeş, biri diğerinin
        // içinde değil. Metnin kendi satırına inmesi sorun değil, maddenin
        // içeriği zaten orası.
        let output = html("<ul><li>bir<li>iki</ul>")
        XCTAssertEqual(output, """
        <ul>
          <li>
            bir
          <li>
            iki
        </ul>
        """)
    }

    func testUnclosedParagraphsStaySiblings() {
        let output = html("<div><p>bir<p>iki</div>")
        XCTAssertEqual(output, """
        <div>
          <p>
            bir
          <p>
            iki
        </div>
        """)
    }

    func testUnclosedTableCellsStaySiblings() {
        let output = html("<tr><td>a<td>b</tr>")
        XCTAssertEqual(output, """
        <tr>
          <td>
            a
          <td>
            b
        </tr>
        """)
    }

    func testExplicitlyClosedItemsAreUnaffected() {
        let output = html("<ul><li>bir</li><li>iki</li></ul>")
        XCTAssertEqual(output, """
        <ul>
          <li>bir</li>
          <li>iki</li>
        </ul>
        """)
    }

    func testXMLIsNotAffectedByHTMLImplicitRules() {
        // XML'de <li> diye bir kural yok; kapatılmamış etiket hatadır.
        XCTAssertThrowsError(try MarkupFormatter.beautify("<ul><li>bir<li>iki</ul>", flavor: .xml))
    }
}

/// 2026-10-18: script/style içeriği etiket sanılıyor, pre içeriği yeniden
/// girintilenip değişiyordu.
final class MarkupRawTextTests: XCTestCase {
    func testScriptContentIsNotParsedAsTags() throws {
        let result = try MarkupFormatter.beautify("<head><script>if (a < b) { x() }</script></head>", flavor: .html)
        XCTAssertEqual(result, "<head>\n  <script>\n    if (a < b) { x() }\n  </script>\n</head>")
    }

    func testStyleKeepsItsOwnIndentation() throws {
        let result = try MarkupFormatter.beautify("<style>\n      a {\n        color: red;\n      }\n</style>", flavor: .html)
        XCTAssertEqual(result, "<style>\n  a {\n    color: red;\n  }\n</style>")
    }

    func testPreAndTextareaAreKeptByteForByte() throws {
        let result = try MarkupFormatter.beautify("<div><pre>  a\n   b </pre><textarea> x\n</textarea></div>", flavor: .html)
        XCTAssertTrue(result.contains("<pre>  a\n   b </pre>"), result)
        XCTAssertTrue(result.contains("<textarea> x\n</textarea>"), result)
    }

    func testClosingTagMatchIsCaseInsensitiveAndWholeWord() throws {
        let result = try MarkupFormatter.beautify("<SCRIPT>var s = '</scripts>';</SCRIPT><p>x</p>", flavor: .html)
        XCTAssertTrue(result.contains("var s = '</scripts>';"), result)
        XCTAssertTrue(result.contains("<p>x</p>"), result)
    }

    func testXMLIsUnaffected() throws {
        // XML'de script sıradan bir eleman.
        XCTAssertEqual(try MarkupFormatter.beautify("<a><script><b/></script></a>", flavor: .xml),
                       "<a>\n  <script>\n    <b/>\n  </script>\n</a>")
    }
}
