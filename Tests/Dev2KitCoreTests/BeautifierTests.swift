import XCTest
@testable import Dev2KitCore

final class BeautifierTests: XCTestCase {
    // MARK: - Tür tahmini

    func testContentTypeWins() {
        XCTAssertEqual(Beautifier.kind(contentType: "application/json; charset=utf-8", body: "<x/>"), .json)
        XCTAssertEqual(Beautifier.kind(contentType: "text/xml", body: "{}"), .xml)
        XCTAssertEqual(Beautifier.kind(contentType: "text/html", body: "{}"), .html)
        XCTAssertEqual(Beautifier.kind(contentType: "application/javascript", body: ""), .javascript)
    }

    func testFallsBackToBodyWhenHeaderIsUnhelpful() {
        // Sunucuların JSON'u text/plain ile göndermesi yaygın.
        XCTAssertEqual(Beautifier.kind(contentType: "text/plain", body: " {\"a\":1}"), .json)
        XCTAssertEqual(Beautifier.kind(contentType: "", body: "[1,2]"), .json)
        XCTAssertEqual(Beautifier.kind(contentType: "", body: "<root/>"), .xml)
    }

    func testPlainWhenNothingMatches() {
        XCTAssertEqual(Beautifier.kind(contentType: "text/plain", body: "merhaba"), .plain)
    }

    // MARK: - Biçimlendirme

    func testJSONIsBeautified() throws {
        let formatted = try Beautifier.beautify("{\"a\":1}", as: .json)
        XCTAssertTrue(formatted.contains("\n"), "JSON satırlara bölünmeliydi: \(formatted)")
    }

    func testPlainIsReturnedUntouched() throws {
        XCTAssertEqual(try Beautifier.beautify("ham metin", as: .plain), "ham metin")
    }

    func testBrokenContentThrows() {
        XCTAssertThrowsError(try Beautifier.beautify("{bozuk", as: .json))
    }

    func testDisplayPathKeepsOriginalOnFailure() {
        // Görüntülerken hata göstermek yerine metni olduğu gibi bırak.
        XCTAssertEqual(Beautifier.beautifiedOrOriginal("{bozuk", as: .json), "{bozuk")
    }
}
