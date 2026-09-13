import XCTest
@testable import BoltDockCore

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
