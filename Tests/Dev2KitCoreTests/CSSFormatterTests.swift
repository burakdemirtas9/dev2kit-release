import XCTest
@testable import Dev2KitCore

final class CSSFormatterTests: XCTestCase {
    func testFormatsRulesAndDeclarations() throws {
        let result = try CSSFormatter.beautify("a{color:red;margin:0 auto}b,i{font-weight:bold}")
        XCTAssertEqual(result, "a {\n  color: red;\n  margin: 0 auto\n}\n\nb, i {\n  font-weight: bold\n}")
    }

    func testSelectorColonsAreUntouched() throws {
        // `div :hover` ile `div:hover` farklı seçiciler; boşluk korunmalı.
        let result = try CSSFormatter.beautify("a:hover{color:red}div :first-child{x:1}")
        XCTAssertTrue(result.hasPrefix("a:hover {"), result)
        XCTAssertTrue(result.contains("div :first-child {"), result)
    }

    func testNestedAtRulesIndent() throws {
        let result = try CSSFormatter.beautify("@media (min-width: 600px){a{color:red}}")
        XCTAssertEqual(result, "@media (min-width: 600px) {\n  a {\n    color: red\n  }\n}")
    }

    func testCommentsStringsAndURLs() throws {
        let result = try CSSFormatter.beautify("/* baş */ a{background:url(http://x/y.png); content:\"a;b{\"}")
        XCTAssertTrue(result.hasPrefix("/* baş */"), result)
        XCTAssertTrue(result.contains("background: url(http://x/y.png);"), result)
        XCTAssertTrue(result.contains("content: \"a;b{\""), result)
    }

    func testUnbalancedBracesThrow() {
        XCTAssertThrowsError(try CSSFormatter.beautify("a{color:red"))
        XCTAssertThrowsError(try CSSFormatter.beautify("a{}}"))
        XCTAssertThrowsError(try CSSFormatter.beautify("   "))
    }

    func testMinify() throws {
        XCTAssertEqual(try CSSFormatter.minify("a {\n  color: red;\n  margin: 0 auto;\n}\n/* x */\nb > i , u { x : 1 }"),
                       "a{color:red;margin:0 auto}b>i,u{x:1}")
        // Seçicideki anlamlı boşluk kalır.
        XCTAssertEqual(try CSSFormatter.minify("div :hover { a: 1 }"), "div :hover{a:1}")
        XCTAssertEqual(try CSSFormatter.minify("a { content: \"x  y\" }"), "a{content:\"x  y\"}")
    }

    func testBeautifierRoutesCSS() throws {
        XCTAssertEqual(Beautifier.kind(contentType: "text/css; charset=utf-8", body: ""), .css)
        XCTAssertEqual(try Beautifier.beautify("a{b:c}", as: .css), "a {\n  b: c\n}")
    }
}
