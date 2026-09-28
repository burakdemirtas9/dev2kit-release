import XCTest
@testable import Dev2KitCore

final class MarkupFoldingTests: XCTestCase {
    private func text(_ lines: String...) -> String {
        lines.joined(separator: "\n")
    }

    func testElementSpanningLinesIsFoldable() {
        let xml = text("<katalog>", "  <urun>Kalem</urun>", "</katalog>")
        let regions = MarkupFolding.regions(in: xml)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.openLine, 0)
        XCTAssertEqual(regions.first?.closeLine, 2)
        XCTAssertEqual(regions.first?.kind, .element)
    }

    func testSingleLineElementIsNotFoldable() {
        XCTAssertTrue(MarkupFolding.regions(in: "<ad>Kalem</ad>").isEmpty)
    }

    func testNestedElementsAreAllReported() {
        let xml = text("<a>", "  <b>", "    <c>x</c>", "  </b>", "</a>")
        let regions = MarkupFolding.regions(in: xml)
        XCTAssertEqual(regions.count, 2, "\(regions)")
        XCTAssertEqual(regions.map(\.openLine), [0, 1])
    }

    func testVoidElementsDoNotOpenRegion() {
        // <img> ve <br> kapanmaz; bunları bölge açtırmak belgenin geri
        // kalanını yanlış katlardı.
        let html = text("<div>", "  <img src=\"a.png\">", "  <br>", "</div>")
        let regions = MarkupFolding.regions(in: html)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.openLine, 0)
    }

    func testSelfClosingTagDoesNotOpenRegion() {
        let xml = text("<liste>", "  <bos />", "</liste>")
        XCTAssertEqual(MarkupFolding.regions(in: xml).count, 1)
    }

    func testGreaterThanInsideAttributeIsNotTagEnd() {
        let html = text("<div title=\"1 > 0\">", "  metin", "</div>")
        let regions = MarkupFolding.regions(in: html)
        XCTAssertEqual(regions.count, 1, "\(regions)")
        XCTAssertEqual(regions.first?.closeLine, 2)
    }

    func testCommentsAreSkipped() {
        // Yorumun içindeki etiket gerçek etiket değildir.
        let xml = text("<a>", "  <!-- <b> yorum </b> -->", "  <c>x</c>", "</a>")
        let regions = MarkupFolding.regions(in: xml)
        XCTAssertEqual(regions.count, 1, "\(regions)")
    }

    func testCDATAIsSkipped() {
        let xml = text("<a>", "  <![CDATA[ <b>bu metin</b> ]]>", "</a>")
        XCTAssertEqual(MarkupFolding.regions(in: xml).count, 1)
    }

    func testProcessingInstructionAndDoctypeDoNotOpenRegion() {
        let html = text("<?xml version=\"1.0\"?>", "<!DOCTYPE html>", "<html>", "  <body>x</body>", "</html>")
        let regions = MarkupFolding.regions(in: html)
        XCTAssertEqual(regions.count, 1, "\(regions)")
        XCTAssertEqual(regions.first?.openLine, 2)
    }

    func testUnclosedTagIsIgnoredNotCrashing() {
        XCTAssertTrue(MarkupFolding.regions(in: text("<a>", "  <b>", "  metin")).isEmpty)
    }

    func testStrayClosingTagIsIgnored() {
        XCTAssertTrue(MarkupFolding.regions(in: text("</a>", "metin")).isEmpty)
    }

    func testMismatchedNestingDropsInnerOpens() {
        // Kapatılmayan <li>: dış <ul> yine de doğru katlanmalı.
        let html = text("<ul>", "  <li>bir", "  <li>iki", "</ul>")
        let regions = MarkupFolding.regions(in: html)
        XCTAssertEqual(regions.count, 1, "\(regions)")
        XCTAssertEqual(regions.first?.openLine, 0)
        XCTAssertEqual(regions.first?.closeLine, 3)
    }

    func testTagNameIsCaseInsensitive() {
        let html = text("<DIV>", "  metin", "</div>")
        XCTAssertEqual(MarkupFolding.regions(in: html).count, 1)
    }

    func testNamespacedTagsMatch() {
        let xml = text("<soap:Envelope>", "  <soap:Body>x</soap:Body>", "</soap:Envelope>")
        XCTAssertEqual(MarkupFolding.regions(in: xml).count, 1)
    }

    func testMultilineOpeningTagUsesItsStartLine() {
        let xml = text("<urun", "  id=\"1\">", "  <ad>Kalem</ad>", "</urun>")
        let regions = MarkupFolding.regions(in: xml)
        XCTAssertEqual(regions.count, 1, "\(regions)")
        XCTAssertEqual(regions.first?.openLine, 0)
        XCTAssertEqual(regions.first?.closeLine, 3)
    }

    func testHiddenRangeKeepsClosingLineVisible() {
        // JSON tarafıyla aynı sözleşme: kapanış etiketi kendi satırında kalır.
        let xml = text("<a>", "  <b>x</b>", "</a>")
        let region = MarkupFolding.regions(in: xml)[0]
        let hidden = (xml as NSString).substring(with: region.hiddenRange)
        XCTAssertFalse(hidden.contains("</a>"), "gizlenen: \(hidden)")
        XCTAssertTrue(hidden.contains("<b>"))
    }

    func testOutermostWorksForMarkup() {
        let xml = text("<a>", "  <b>", "    <c>x</c>", "  </b>", "</a>")
        let regions = MarkupFolding.regions(in: xml)
        XCTAssertEqual(FoldRegion.outermost(regions).count, 1)
    }

    func testEmptyTextHasNoRegions() {
        XCTAssertTrue(MarkupFolding.regions(in: "").isEmpty)
    }
}
