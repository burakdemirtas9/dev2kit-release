import XCTest
@testable import Dev2KitCore

final class ScriptFormatterTests: XCTestCase {
    func testIndentsFunctionBody() throws {
        let result = try ScriptFormatter.beautify("function f(){const a=1;return a;}")
        XCTAssertEqual(result, """
        function f() {
          const a=1;
          return a;
        }
        """)
    }

    func testObjectLiteralFieldsOnOwnLines() throws {
        let result = try ScriptFormatter.beautify("const o={a:1,b:2};")
        XCTAssertEqual(result, """
        const o= {
          a: 1,
          b: 2
        };
        """)
    }

    func testArrayArgumentsStayInline() throws {
        let result = try ScriptFormatter.beautify("f(1,2,[3,4]);")
        XCTAssertEqual(result, "f(1, 2, [3, 4]);")
    }

    func testStringContentUntouched() throws {
        let result = try ScriptFormatter.beautify("const s='a{b};c';")
        XCTAssertTrue(result.contains("'a{b};c'"))
    }

    func testTemplateLiteralWithNewlinesPreserved() throws {
        let result = try ScriptFormatter.beautify("const t=`sat\nır`;")
        XCTAssertTrue(result.contains("`sat\nır`"))
    }

    func testCommentsPreservedOnOwnLine() throws {
        let result = try ScriptFormatter.beautify("const a=1;// not\nconst b=2;")
        XCTAssertTrue(result.contains("// not"))
        XCTAssertTrue(result.contains("const b=2;"))
    }

    func testRegexLiteralNotTreatedAsComment() throws {
        let result = try ScriptFormatter.beautify("const r=/a\\/b/gi;")
        XCTAssertTrue(result.contains("/a\\/b/gi"))
    }

    func testDivisionNotTreatedAsRegex() throws {
        let result = try ScriptFormatter.beautify("const x=a/b;const y=2;")
        XCTAssertTrue(result.contains("a/b;"))
        XCTAssertTrue(result.contains("const y=2;"))
    }

    func testForLoopSemicolonsStayInline() throws {
        let result = try ScriptFormatter.beautify("for(let i=0;i<3;i++){x();}")
        XCTAssertTrue(result.contains("for(let i=0;i<3;i++)"))
    }

    func testEmptyBodyStaysInline() throws {
        let result = try ScriptFormatter.beautify("function f(){}")
        XCTAssertEqual(result, "function f() {}")
    }

    func testUnbalancedBraceThrows() {
        XCTAssertThrowsError(try ScriptFormatter.beautify("function f(){"))
        XCTAssertThrowsError(try ScriptFormatter.beautify("}"))
    }

    func testUnterminatedStringThrows() {
        XCTAssertThrowsError(try ScriptFormatter.beautify("const s='açık;"))
    }

    func testEmptyThrows() {
        XCTAssertThrowsError(try ScriptFormatter.beautify("  "))
    }
}

/// 2026-10-18'de bulunan hatalar: satır sonları siliniyordu (ASI), TS
/// generic'lerindeki virgül satır kırıyordu.
final class ScriptFormatterLineBreakTests: XCTestCase {
    func testNewlinesWithoutSemicolonsArePreserved() throws {
        XCTAssertEqual(try ScriptFormatter.beautify("let a = 1\nlet b = 2\nfoo()"), "let a = 1\nlet b = 2\nfoo()")
    }

    func testReturnFollowedByNewlineKeepsItsMeaning() throws {
        // `return⏎x` undefined döndürür; birleştirmek anlamı değiştirirdi.
        let result = try ScriptFormatter.beautify("function f() {\n  return\n  x\n}")
        XCTAssertEqual(result, "function f() {\n  return\n  x\n}")
    }

    func testBlankLinesCollapseAndArgumentsStayInline() throws {
        XCTAssertEqual(try ScriptFormatter.beautify("a()\n\n\nb()"), "a()\nb()")
        XCTAssertEqual(try ScriptFormatter.beautify("f(1,\n  2)"), "f(1, 2)")
    }

    func testTypeScriptGenericsStayOnOneLine() throws {
        let result = try ScriptFormatter.beautify("function id<T>(x: T): Array<T> { const m: Map<string, number> = new Map(); return [x] }")
        XCTAssertTrue(result.contains("const m: Map<string, number> = new Map();"), result)
    }

    func testComparisonsAreNotMistakenForGenerics() throws {
        let result = try ScriptFormatter.beautify("if (a<b) { x(1, 2) } const o = {a: 1, b: 2}")
        XCTAssertTrue(result.contains("if (a<b) {"), result)
        XCTAssertTrue(result.contains("a: 1,\n"), "nesne alanları yine ayrı satırda: \(result)")
    }
}
