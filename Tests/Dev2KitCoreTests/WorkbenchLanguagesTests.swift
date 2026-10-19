import XCTest
@testable import Dev2KitCore

final class StructureCheckTests: XCTestCase {
    private func issue(_ text: String, _ rules: StructureCheck.Rules = .css) -> WorkbenchIssue? {
        if case .invalid(let issue) = StructureCheck.validate(text, rules: rules) { return issue }
        return nil
    }

    func testBalancedCodeIsStructurallyValidNotValid() {
        XCTAssertEqual(StructureCheck.validate("a { b: url(x) } @media (x) { c { d: e } }", rules: .css), .structurallyValid)
        XCTAssertEqual(StructureCheck.validate("   ", rules: .css), .empty)
    }

    func testReportsPositionOfTheProblem() throws {
        let mismatch = try XCTUnwrap(issue("a {\n  b: f(\n}"))
        XCTAssertEqual(mismatch.line, 3)
        XCTAssertTrue(mismatch.message.contains("( kapatılmadan } geldi"), mismatch.message)

        let open = try XCTUnwrap(issue("a {\n  b: c"))
        XCTAssertEqual(open.line, 1)
        XCTAssertEqual(open.column, 3)

        XCTAssertNotNil(issue("a { content: 'açık }"))
        XCTAssertNotNil(issue("/* kapanmamış"))
    }

    func testBracketsInsideStringsAndCommentsAreIgnored() {
        XCTAssertNil(issue("a { content: \"{(\" } /* ) } */"))
    }

    func testCSSHasNoLineComments() {
        // `url(http://…)` içindeki `//` yorum değil.
        XCTAssertNil(issue("a { background: url(http://x/y.png) }"))
        XCTAssertNotNil(issue("a { color: red"))
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

final class WorkbenchLanguageToolsTests: XCTestCase {
    func testOnlyJSONHasEscapeActions() {
        // Kullanıcı kararı: kaçış kuralı bağlama göre değişiyor; yalnızca JSON'da kaldı.
        for tool in WorkbenchCatalog.all where tool.id != "json" {
            XCTAssertFalse(tool.actions.contains { $0.id == "escape" || $0.id == "unescape" }, tool.id)
        }
        XCTAssertEqual(WorkbenchTools.json.actions.map(\.id), ["format", "minify", "escape", "unescape"])
    }

    func testCatalogHasStep1bTools() {
        XCTAssertEqual(WorkbenchCatalog.all.filter { $0.category == .format }.map(\.id), ["json", "xml", "html", "css", "sql", "markdown"])
        // JavaScript/TypeScript biçimlendiricisi kaldırıldı (kullanıcı kararı);
        // "typescript" yalnızca Object Converter'daki tip üreticilerini bulur.
        XCTAssertEqual(WorkbenchCatalog.matching("typescript").map(\.id), ["json-to-ts-interface", "json-to-ts-type"])
        XCTAssertEqual(WorkbenchCatalog.matching("soap").map(\.id), ["xml", "json-to-xml"])
    }

    func testEveryToolsActionsReverse() throws {
        let samples = [
            "xml": "<a><b x=\"1\">t &amp; u</b></a>",
            "html": "<div><p>Ali &amp; Veli</p></div>",
            "css": "a{color:red}",
            "sql": "select a from t where b = 'x'",
            "markdown": "# Başlık\n\n| a | b |\n| - | - |\n| 1 | 2 |",
        ]
        // Dönüştürücülerin tersi yok (WorkbenchConvertCatalogTests).
        for tool in WorkbenchCatalog.all where tool.id != "json" && tool.category == .format {
            let sample = try XCTUnwrap(samples[tool.id], tool.id)
            for action in tool.actions {
                let output = try action.run(sample, .init())
                XCTAssertEqual(try action.reverse?(output, sample, .init()), output, "\(tool.id) \(action.id) tersi")
            }
            XCTAssertNoThrow(try tool.action(id: "format").run(sample, .init()), tool.id)
            if tool.actions.contains(where: { $0.id == "minify" }) {
                XCTAssertNoThrow(try tool.action(id: "minify").run(sample, .init()), tool.id)
            }
            XCTAssertNotEqual(tool.validate?(sample), nil)
        }
    }
}
