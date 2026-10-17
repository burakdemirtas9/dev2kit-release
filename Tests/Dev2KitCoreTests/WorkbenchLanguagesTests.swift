import XCTest
@testable import Dev2KitCore

final class StructureCheckTests: XCTestCase {
    private func issue(_ text: String, _ rules: StructureCheck.Rules = .javascript) -> WorkbenchIssue? {
        if case .invalid(let issue) = StructureCheck.validate(text, rules: rules) { return issue }
        return nil
    }

    func testBalancedCodeIsStructurallyValidNotValid() {
        XCTAssertEqual(StructureCheck.validate("function f(a) { return [a, (1)] }", rules: .javascript), .structurallyValid)
        XCTAssertEqual(StructureCheck.validate("   ", rules: .javascript), .empty)
    }

    func testReportsPositionOfTheProblem() throws {
        let unclosed = try XCTUnwrap(issue("function f() {\n  x(\n}"))
        XCTAssertEqual(unclosed.line, 3)
        XCTAssertTrue(unclosed.message.contains("( kapatılmadan } geldi"), unclosed.message)

        let open = try XCTUnwrap(issue("if (a) {\n  b()"))
        XCTAssertEqual(open.line, 1)
        XCTAssertEqual(open.column, 8)

        XCTAssertNotNil(issue("const s = 'açık"))
        XCTAssertNotNil(issue("/* kapanmamış"))
    }

    func testBracketsInsideStringsCommentsAndRegexAreIgnored() {
        XCTAssertNil(issue("const s = \"{(\"; // )}\nconst r = /[}/g; const t = `${a}\n]`"))
    }

    func testCSSHasNoLineComments() {
        // `url(http://…)` içindeki `//` yorum değil.
        XCTAssertNil(issue("a { background: url(http://x/y.png) }", .css))
        XCTAssertNotNil(issue("a { color: red", .css))
    }
}

final class MarkupToolsTests: XCTestCase {
    func testXMLValidationWithPosition() throws {
        XCTAssertEqual(MarkupTools.validateXML("<a><b>1</b></a>"), .valid)
        guard case .invalid(let issue) = MarkupTools.validateXML("<a>\n  <b>1</c>\n</a>") else { return XCTFail() }
        XCTAssertEqual(issue.line, 2)
        XCTAssertTrue(issue.message.contains("eşleşmiyor"), issue.message)
    }

    func testXMLDoesNotResolveExternalEntities() {
        // XXE: dış varlık çözülseydi /etc/passwd okunurdu; çözülmüyor, belge
        // yine de değerlendiriliyor ve hiçbir dosya içeriği sızmıyor.
        let xxe = "<?xml version=\"1.0\"?><!DOCTYPE a [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><a>&x;</a>"
        let result = MarkupTools.validateXML(xxe)
        if case .invalid(let issue) = result { XCTAssertFalse(issue.message.contains("root:")) }
    }

    func testHTMLCheck() throws {
        XCTAssertEqual(MarkupTools.checkHTML("<ul><li>a<li>b</ul><p>x<br>y"), .structurallyValid, "kapanışı isteğe bağlı etiketler hata değil")
        XCTAssertEqual(MarkupTools.checkHTML("<script>if (a < b) {}</script><p>ok</p>"), .structurallyValid)
        guard case .invalid(let unclosed) = MarkupTools.checkHTML("<div>\n  <span>x\n</div>") else { return XCTFail() }
        XCTAssertTrue(unclosed.message.contains("<span> kapatılmadan </div>"), unclosed.message)
        XCTAssertEqual(unclosed.line, 3)
        guard case .invalid(let stray) = MarkupTools.checkHTML("<p>x</p></section>") else { return XCTFail() }
        XCTAssertTrue(stray.message.contains("</section> için açılış"), stray.message)
        guard case .invalid(let open) = MarkupTools.checkHTML("<main><div>x") else { return XCTFail() }
        XCTAssertTrue(open.message.contains("<div> kapatılmamış"), open.message)
    }

    func testMinify() throws {
        XCTAssertEqual(try MarkupTools.minify("<a>\n  <!-- not -->\n  <b>1</b>\n  <![CDATA[ x  y ]]>\n</a>", html: false),
                       "<a><b>1</b><![CDATA[ x  y ]]></a>")
        // HTML'de boşluk tek boşluğa iner (satır içi öğeler arası görünür).
        XCTAssertEqual(try MarkupTools.minify("<p>\n  <b>a</b>\n  <i>b</i>   metin\n</p>", html: true),
                       "<p> <b>a</b> <i>b</i> metin </p>")
        XCTAssertEqual(try MarkupTools.minify("<pre>  a\n b</pre>", html: true), "<pre>  a\n b</pre>")
    }
}

final class ScriptToolsTests: XCTestCase {
    func testMinifyKeepsMeaningfulLineBreaks() throws {
        XCTAssertEqual(try ScriptTools.minifyJavaScript("let a = 1\nlet b = 2\n// yorum\nfoo( a , b );\n"),
                       "let a=1\nlet b=2\nfoo(a,b);")
        XCTAssertEqual(try ScriptTools.minifyJavaScript("function f() {\n  return\n  x\n}"), "function f(){return\nx}")
        XCTAssertEqual(try ScriptTools.minifyJavaScript("a + +b; c - -d"), "a + +b;c - -d")
        XCTAssertEqual(try ScriptTools.minifyJavaScript("const s = 'a  b' /* x */ ; const r = /a b/g"), "const s='a  b';const r=/a b/g")
    }
}

final class WorkbenchLanguageToolsTests: XCTestCase {
    func testOnlyJSONHasEscapeActions() {
        // Kullanıcı kararı: kaçış kuralı bağlama göre değişiyor; yalnızca JSON'da kaldı.
        for tool in WorkbenchCatalog.all where tool.id != "json" {
            XCTAssertEqual(tool.actions.map(\.id), ["format", "minify"], tool.id)
        }
        XCTAssertEqual(WorkbenchTools.json.actions.map(\.id), ["format", "minify", "escape", "unescape"])
    }

    func testCatalogHasStep1bTools() {
        XCTAssertEqual(WorkbenchCatalog.all.map(\.id), ["json", "xml", "html", "css", "javascript", "typescript"])
        XCTAssertEqual(WorkbenchCatalog.matching("ts").first?.id, "typescript")
        XCTAssertEqual(WorkbenchCatalog.matching("soap").map(\.id), ["xml"])
    }

    func testEveryToolsActionsReverse() throws {
        let samples = [
            "xml": "<a><b x=\"1\">t &amp; u</b></a>",
            "html": "<div><p>Ali &amp; Veli</p></div>",
            "css": "a{color:red}",
            "javascript": "const a = {b: \"x\"}",
            "typescript": "const m: Map<string, number> = new Map()",
        ]
        for tool in WorkbenchCatalog.all where tool.id != "json" {
            let sample = try XCTUnwrap(samples[tool.id], tool.id)
            for action in tool.actions {
                let output = try action.run(sample, .init())
                XCTAssertEqual(try action.reverse?(output, sample, .init()), output, "\(tool.id) \(action.id) tersi")
            }
            XCTAssertNoThrow(try tool.action(id: "format").run(sample, .init()), tool.id)
            XCTAssertNoThrow(try tool.action(id: "minify").run(sample, .init()), tool.id)
            XCTAssertNotEqual(tool.validate?(sample), nil)
        }
    }
}
