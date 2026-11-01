import XCTest
@testable import Dev2KitCore

/// Markdown → HTML (Markdown Viewer, 2026-11-01). Beklenen çıktılar
/// CommonMark / GitHub davranışı; ham HTML olduğu gibi geçer (kullanıcı kararı).
final class MarkdownRendererTests: XCTestCase {
    private func render(_ markdown: String) -> String {
        MarkdownRenderer.html(markdown)
    }

    // MARK: Bloklar

    func testHeadings() {
        XCTAssertEqual(render("# Başlık"), "<h1>Başlık</h1>\n")
        XCTAssertEqual(render("### Üç ###"), "<h3>Üç</h3>\n")
        XCTAssertEqual(render("####### yedi"), "<p>####### yedi</p>\n", "en çok 6 seviye")
        XCTAssertEqual(render("#etiket"), "<p>#etiket</p>\n", "boşluksuz # başlık değil")
        XCTAssertEqual(render("Alt\n==="), "<h1>Alt</h1>\n")
        XCTAssertEqual(render("Alt\n---"), "<h2>Alt</h2>\n")
    }

    func testParagraphsAndLineBreaks() {
        XCTAssertEqual(render("bir\niki\n\nüç"), "<p>bir\niki</p>\n<p>üç</p>\n")
        XCTAssertEqual(render("bir  \niki"), "<p>bir<br />\niki</p>\n")
        XCTAssertEqual(render("bir\\\niki"), "<p>bir<br />\niki</p>\n")
    }

    func testRules() {
        XCTAssertEqual(render("---"), "<hr />\n")
        XCTAssertEqual(render("* * *"), "<hr />\n")
        XCTAssertEqual(render("a\n\n___"), "<p>a</p>\n<hr />\n")
    }

    func testFencedCodeIsEscapedAndKeepsLanguage() {
        XCTAssertEqual(
            render("```json\n{\"a\": \"<b>\"}\n```"),
            "<pre><code class=\"language-json\">{&quot;a&quot;: &quot;&lt;b&gt;&quot;}\n</code></pre>\n"
        )
        XCTAssertEqual(render("~~~\nx\n~~~"), "<pre><code>x\n</code></pre>\n")
        XCTAssertEqual(render("```\nkapanmamış"), "<pre><code>kapanmamış\n</code></pre>\n", "kapanmayan çit sona kadar sürer")
        XCTAssertEqual(render("    girintili\n    kod"), "<pre><code>girintili\nkod\n</code></pre>\n")
    }

    func testBlockquoteNestingAndLazyContinuation() {
        XCTAssertEqual(render("> alıntı"), "<blockquote>\n<p>alıntı</p>\n</blockquote>\n")
        XCTAssertEqual(render("> a\nb"), "<blockquote>\n<p>a\nb</p>\n</blockquote>\n")
        XCTAssertEqual(render("> > iç"), "<blockquote>\n<blockquote>\n<p>iç</p>\n</blockquote>\n</blockquote>\n")
    }

    func testTightAndLooseLists() {
        XCTAssertEqual(render("- a\n- b"), "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")
        XCTAssertEqual(render("- a\n\n- b"), "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n")
        XCTAssertEqual(render("3. üç\n4. dört"), "<ol start=\"3\">\n<li>üç</li>\n<li>dört</li>\n</ol>\n")
        XCTAssertEqual(render("1) a"), "<ol>\n<li>a</li>\n</ol>\n")
    }

    func testNestedList() {
        XCTAssertEqual(
            render("- a\n  - b\n- c"),
            "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n<li>c</li>\n</ul>\n"
        )
    }

    func testDifferentBulletStartsNewList() {
        XCTAssertEqual(render("- a\n+ b"), "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n")
    }

    func testTaskList() {
        XCTAssertEqual(
            render("- [x] bitti\n- [ ] kaldı"),
            "<ul>\n<li class=\"task\"><input type=\"checkbox\" disabled checked> bitti</li>\n"
                + "<li class=\"task\"><input type=\"checkbox\" disabled> kaldı</li>\n</ul>\n"
        )
    }

    func testOrderedListOnlyInterruptsParagraphFromOne() {
        XCTAssertEqual(render("yıl\n2024. iyi"), "<p>yıl\n2024. iyi</p>\n")
        XCTAssertEqual(render("liste\n1. ilk"), "<p>liste</p>\n<ol>\n<li>ilk</li>\n</ol>\n")
    }

    func testTableWithAlignmentAndEscapedPipe() {
        XCTAssertEqual(
            render("| a | b | c |\n|:--|:-:|--:|\n| 1 | x\\|y | `k` |"),
            """
            <table>
            <thead>
            <tr>
            <th style="text-align:left">a</th>
            <th style="text-align:center">b</th>
            <th style="text-align:right">c</th>
            </tr>
            </thead>
            <tbody>
            <tr>
            <td style="text-align:left">1</td>
            <td style="text-align:center">x|y</td>
            <td style="text-align:right"><code>k</code></td>
            </tr>
            </tbody>
            </table>

            """
        )
    }

    func testTableRowsArePaddedToHeader() {
        let html = render("a | b\n--|--\nyalnız")
        XCTAssertTrue(html.contains("<td>yalnız</td>\n<td></td>"), html)
    }

    func testTableInterruptsParagraph() {
        XCTAssertTrue(render("metin\n| a |\n|---|\n| 1 |").hasPrefix("<p>metin</p>\n<table>"))
    }

    // MARK: Satır içi

    func testEmphasis() {
        XCTAssertEqual(render("*em* **strong** ***ikisi***"),
                       "<p><em>em</em> <strong>strong</strong> <em><strong>ikisi</strong></em></p>\n")
        XCTAssertEqual(render("_a_ __b__ ~~c~~"), "<p><em>a</em> <strong>b</strong> <del>c</del></p>\n")
        XCTAssertEqual(render("snake_case_name"), "<p>snake_case_name</p>\n", "kelime içi _ vurgu değil")
        XCTAssertEqual(render("2 * 3 * 4"), "<p>2 * 3 * 4</p>\n")
        XCTAssertEqual(render("**kapanmamış"), "<p>**kapanmamış</p>\n")
    }

    func testCodeSpans() {
        XCTAssertEqual(render("`a<b>`"), "<p><code>a&lt;b&gt;</code></p>\n")
        XCTAssertEqual(render("`` a ` b ``"), "<p><code>a ` b</code></p>\n")
        XCTAssertEqual(render("`*vurgu değil*`"), "<p><code>*vurgu değil*</code></p>\n")
        XCTAssertEqual(render("`açık"), "<p>`açık</p>\n")
    }

    func testEscapes() {
        XCTAssertEqual(render("\\*yıldız\\*"), "<p>*yıldız*</p>\n")
        XCTAssertEqual(render("a & b < c"), "<p>a &amp; b &lt; c</p>\n")
        XCTAssertEqual(render("&copy; &#169; &#xA9;"), "<p>&copy; &#169; &#xA9;</p>\n")
    }

    func testLinks() {
        XCTAssertEqual(render("[dev2kit](https://ornek.test \"Başlık\")"),
                       "<p><a href=\"https://ornek.test\" title=\"Başlık\">dev2kit</a></p>\n")
        XCTAssertEqual(render("[**kalın**](/yol)"), "<p><a href=\"/yol\"><strong>kalın</strong></a></p>\n")
        XCTAssertEqual(render("[a](<yol boşluk>)"), "<p><a href=\"yol%20boşluk\">a</a></p>\n")
        XCTAssertEqual(render("[bağlantı yok]"), "<p>[bağlantı yok]</p>\n")
    }

    func testReferenceLinks() {
        let markdown = "[tam][ref], [kısa] ve [boş][]\n\n[ref]: https://a.test \"T\"\n[Kısa]: https://b.test\n[boş]: https://c.test"
        XCTAssertEqual(
            render(markdown),
            "<p><a href=\"https://a.test\" title=\"T\">tam</a>, <a href=\"https://b.test\">kısa</a> ve "
                + "<a href=\"https://c.test\">boş</a></p>\n"
        )
    }

    func testNoLinksInsideLinks() {
        XCTAssertEqual(render("[a [b](/iç)](/dış)"), "<p>[a <a href=\"/iç\">b</a>](/dış)</p>\n")
    }

    func testImages() {
        XCTAssertEqual(render("![logo *x*](/a.png \"t\")"), "<p><img src=\"/a.png\" alt=\"logo x\" title=\"t\" /></p>\n")
        XCTAssertEqual(render("[![rozet](/r.svg)](/sayfa)"), "<p><a href=\"/sayfa\"><img src=\"/r.svg\" alt=\"rozet\" /></a></p>\n")
    }

    func testAutolinks() {
        XCTAssertEqual(render("<https://a.test/x?y=1>"), "<p><a href=\"https://a.test/x?y=1\">https://a.test/x?y=1</a></p>\n")
        XCTAssertEqual(render("<kisi@ornek.test>"), "<p><a href=\"mailto:kisi@ornek.test\">kisi@ornek.test</a></p>\n")
        XCTAssertEqual(render("bak: https://a.test/yol."), "<p>bak: <a href=\"https://a.test/yol\">https://a.test/yol</a>.</p>\n")
        XCTAssertEqual(render("(www.a.test)"), "<p>(<a href=\"http://www.a.test\">www.a.test</a>)</p>\n")
        XCTAssertEqual(render("whatever"), "<p>whatever</p>\n")
    }

    // MARK: Ham HTML

    func testRawHTMLPassesThrough() {
        XCTAssertEqual(render("<details>\n<summary>Aç</summary>\n\nİçerik\n</details>"),
                       "<details>\n<summary>Aç</summary>\n<p>İçerik</p>\n</details>\n")
        XCTAssertEqual(render("satır<br>içi <b class=\"x\">kalın</b>"), "<p>satır<br>içi <b class=\"x\">kalın</b></p>\n")
        XCTAssertEqual(render("<!-- yorum -->"), "<!-- yorum -->\n")
        XCTAssertEqual(render("a <b"), "<p>a &lt;b</p>\n", "yarım etiket metin")
    }

    // MARK: Güvenlik

    func testDangerousSchemesAreDropped() {
        XCTAssertEqual(render("[x](javascript:alert(1))"), "<p><a>x</a></p>\n")
        XCTAssertEqual(render("[x]( JAVASCRIPT:alert(1))"), "<p><a>x</a></p>\n")
        XCTAssertEqual(render("[x](vbscript:msgbox)"), "<p><a>x</a></p>\n")
        XCTAssertEqual(render("[x](file:///etc/passwd)"), "<p><a>x</a></p>\n")
        XCTAssertEqual(render("[x](data:text/html,<b>)"), "<p><a>x</a></p>\n")
        XCTAssertEqual(render("![x](data:image/png;base64,AAAA)"), "<p><img src=\"data:image/png;base64,AAAA\" alt=\"x\" /></p>\n")
        XCTAssertEqual(render("<javascript:alert(1)>"), "<p>javascript:alert(1)</p>\n")
    }

    func testAttributeValuesAreEscaped() {
        XCTAssertEqual(render("[x](/a\"onmouseover=\"b)"), "<p><a href=\"/a&quot;onmouseover=&quot;b\">x</a></p>\n")
        XCTAssertEqual(render("![\"q\"](/i.png)"), "<p><img src=\"/i.png\" alt=\"&quot;q&quot;\" /></p>\n")
    }

    // MARK: Sınırlar

    func testDeepNestingIsCapped() {
        let quote = String(repeating: ">", count: 2_000) + " derin"
        let html = render(quote)
        XCTAssertEqual(html.components(separatedBy: "<blockquote>").count - 1, MarkdownRenderer.maxNesting + 1)
        XCTAssertTrue(html.contains("derin"))
    }

    /// Kötü niyetli girdiler kare büyümesin: her biri ~100 bin karakter.
    func testPathologicalInputsStayFast() {
        let inputs = [
            String(repeating: "*a ", count: 40_000),
            String(repeating: "_a* ", count: 30_000),
            String(repeating: "[", count: 100_000),
            String(repeating: "[a](", count: 30_000),
            String(repeating: "<a b=\"", count: 20_000),
            String(repeating: "<!--", count: 30_000),
            String(repeating: "`", count: 1) + String(repeating: "a``", count: 30_000),
            String(repeating: "![a](b)", count: 15_000),
            String(repeating: "- ", count: 5_000) + "x",
            String(repeating: "  - a\n", count: 20_000),
            String(repeating: "> ", count: 5_000) + "x",
            String(repeating: "https://a.test/(", count: 6_000),
        ]
        for input in inputs {
            let start = ContinuousClock.now
            _ = render(input)
            let elapsed = start.duration(to: .now)
            XCTAssertLessThan(elapsed, .seconds(3), "yavaş: \(input.prefix(12))…")
        }
    }

    func testLargeDocumentRendersQuickly() {
        let section = "## Başlık\n\nMetin **kalın** ve `kod` [bağlantı](https://a.test).\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n"
        let document = String(repeating: section, count: 20_000) // ~2 MB
        let start = ContinuousClock.now
        let html = render(document)
        XCTAssertLessThan(start.duration(to: .now), .seconds(15))
        XCTAssertEqual(html.components(separatedBy: "<h2>").count - 1, 20_000)
    }

    // MARK: Belge ve araçlar

    func testDocumentWrapsBodyWithStyle() {
        let document = MarkdownRenderer.document("# a")
        XCTAssertTrue(document.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(document.contains("color-scheme"))
        XCTAssertTrue(document.contains("<h1>a</h1>"))
        XCTAssertFalse(document.contains("<script"), "önizleme belgesinde script yok")
    }

    func testPreviewToolsInCatalog() throws {
        let html = try XCTUnwrap(WorkbenchCatalog.tool(id: "html-viewer"))
        let markdown = try XCTUnwrap(WorkbenchCatalog.tool(id: "markdown-viewer"))
        XCTAssertEqual(html.category, .preview)
        XCTAssertEqual(markdown.category, .preview)
        XCTAssertEqual(html.actions.map(\.id), ["preview"])
        XCTAssertEqual(markdown.actions.map(\.id), ["preview", "html"])
        XCTAssertTrue(html.actions[0].rendersPreview)
        XCTAssertTrue(markdown.actions[0].rendersPreview)
        XCTAssertFalse(markdown.actions[1].rendersPreview, "HTML eylemi kod gösterir")
        XCTAssertEqual(markdown.actions[1].outputSyntax, .html)
        XCTAssertNotNil(html.inputFormatter)
        XCTAssertNotNil(markdown.inputFormatter)
        XCTAssertTrue(WorkbenchCatalog.matching("önizle").contains { $0.id == "markdown-viewer" })
        XCTAssertTrue(WorkbenchCatalog.matching("readme").contains { $0.id == "markdown-viewer" })
    }

    func testPreviewActionsRunOnSamples() throws {
        let html = try XCTUnwrap(WorkbenchCatalog.tool(id: "html-viewer"))
        XCTAssertEqual(try html.actions[0].run(PreviewSamples.html, WorkbenchOptions()), PreviewSamples.html,
                       "HTML olduğu gibi çizilir")
        let markdown = try XCTUnwrap(WorkbenchCatalog.tool(id: "markdown-viewer"))
        let preview = try markdown.actions[0].run(PreviewSamples.markdown, WorkbenchOptions())
        XCTAssertTrue(preview.contains("<h1>dev2kit</h1>"))
        XCTAssertTrue(preview.contains("<table>"))
        XCTAssertTrue(preview.contains("class=\"task\""))
        let code = try markdown.actions[1].run(PreviewSamples.markdown, WorkbenchOptions())
        XCTAssertTrue(code.hasPrefix("<h1>dev2kit</h1>"))
        XCTAssertFalse(code.contains("<style>"), "HTML eylemi yalnızca gövde parçası")
    }
}
