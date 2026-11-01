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

/// Yanıt gövdesi güvenilmeyen sunucudan gelir ve her gönderimde
/// biçimlendirilir (yeniden tarama, 2026-11-01): `{` × 16000 7 sn,
/// SQL `*` × 16000 3,7 sn sürüyordu. Girinti üst sınırlı, tarama erken çıkıyor.
final class BeautifierHostileInputTests: XCTestCase {
    func testDeepOrRepetitiveInputStaysFast() {
        let cases: [(String, Beautifier.Kind)] = [
            (String(repeating: "{", count: 32_000), .javascript),
            (String(repeating: "{", count: 32_000), .css),
            (String(repeating: "*", count: 32_000), .sql),
            (String(repeating: "<b><i>", count: 5_000), .xml),
            (String(repeating: "<b><i>", count: 5_000), .html),
            (String(repeating: "x<y>", count: 8_000), .xml),
        ]
        for (text, kind) in cases {
            let start = Date()
            _ = Beautifier.beautifiedOrOriginal(text, as: kind)
            XCTAssertLessThan(Date().timeIntervalSince(start), 3, "\(kind)")
        }
    }

    func testIndentationIsCappedButStructureIsKept() throws {
        let depth = 100
        let json = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        let pretty = try Beautifier.beautify(json, as: .json)
        let widest = pretty.components(separatedBy: "\n").map { line in line.prefix { $0 == " " }.count }.max() ?? 0
        XCTAssertGreaterThan(widest, 0)
        XCTAssertLessThanOrEqual(widest, IndentedWriter.maxVisibleLevel * 4, "girinti sınırı")
        XCTAssertEqual(pretty.filter { $0 == "[" }.count, depth, "yapı korunur")
        // Sınırın altındaki derinlik eskisi gibi girintilenir.
        XCTAssertEqual(try Beautifier.beautify("[[1]]", as: .json), "[\n  [\n    1\n  ]\n]")
    }
}

/// XML/HTML minify (yeniden inceleme, ölçüldü): kapanmamış her `<` metnin
/// sonuna kadar taranıyordu, 160 KB 54 sn. Tek geçişli tablo eskisiyle aynı.
final class MarkupMinifyHostileInputTests: XCTestCase {
    func testTagEndTableMatchesTheScanner() {
        let alphabet = Array("<>\"'a ")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3_000 {
            let chars = (0..<Int.random(in: 0...30, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            let ends = MarkupTools.tagEnds(chars)
            for start in chars.indices {
                XCTAssertEqual(ends[start] >= 0 ? ends[start] : nil, MarkupTools.tagEnd(chars, from: start), String(chars))
            }
        }
    }

    func testUnclosedTagsStayFast() {
        for text in [String(repeating: "<", count: 160_000), String(repeating: "<a ", count: 50_000),
                     String(repeating: "<'", count: 80_000) + "\" >", String(repeating: "<script>", count: 20_000)] {
            let start = Date()
            _ = try? MarkupTools.minify(text, html: true)
            XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        }
    }

    func testMinifyOutputIsUnchanged() throws {
        XCTAssertEqual(try MarkupTools.minify("<a  href=\"x > y\">  metin   <b>kalın</b> </a>", html: true),
                       "<a  href=\"x > y\"> metin <b>kalın</b> </a>")
        XCTAssertEqual(try MarkupTools.minify("<script> var a = 1 <  2; </script>", html: true),
                       "<script> var a = 1 <  2; </script>")
    }
}
