import XCTest
@testable import Dev2KitCore

final class JSONDocumentTests: XCTestCase {
    func testKeepsKeyOrderAndNumbersVerbatim() throws {
        let value = try JSONDocument.parse(#"{"z":1,"a":12345678901234567890,"m":1.10,"e":-2E+3}"#)
        XCTAssertEqual(value.compact(), #"{"z":1,"a":12345678901234567890,"m":1.10,"e":-2E+3}"#)
    }

    func testSortsKeysAtEveryLevel() throws {
        let value = try JSONDocument.parse(#"{"b":{"y":1,"x":2},"a":[{"d":1,"c":2}]}"#)
        XCTAssertEqual(value.compact(sortKeys: true), #"{"a":[{"c":2,"d":1}],"b":{"x":2,"y":1}}"#)
    }

    func testStringsRoundTripWithEscapesAndUnicode() throws {
        let value = try JSONDocument.parse(#"["satır\nsonu","tırnak\"","\u00e7ğ","😀","\ud83d\ude00","a\/b"]"#)
        XCTAssertEqual(value, .array([.string("satır\nsonu"), .string("tırnak\""), .string("çğ"), .string("😀"), .string("😀"), .string("a/b")]))
        XCTAssertEqual(value.compact(), #"["satır\nsonu","tırnak\"","çğ","😀","😀","a/b"]"#)
    }

    func testCommentsAreWhitespace() throws {
        let value = try JSONDocument.parse("{ // not\n\"a\": /* blok */ 1 }")
        XCTAssertEqual(value.compact(), #"{"a":1}"#)
    }

    private func issue(_ text: String) -> WorkbenchIssue? {
        do { _ = try JSONDocument.parse(text); return nil } catch { return error as? WorkbenchIssue }
    }

    func testErrorsCarryLineAndColumn() throws {
        let error = try XCTUnwrap(issue("{\n  \"a\": 1,\n  \"b\": }"))
        XCTAssertEqual(error.line, 3)
        XCTAssertEqual(error.column, 8)
        XCTAssertTrue(error.message.hasPrefix("Geçersiz JSON"))

        let trailing = try XCTUnwrap(issue("[1, 2,]"))
        XCTAssertTrue(trailing.message.contains("virgül"))
        XCTAssertEqual(trailing.column, 7)
    }

    func testColumnCountsCharactersNotBytes() throws {
        // "ğ" iki bayt; sütun karakter sayısı olmalı.
        let error = try XCTUnwrap(issue(#"{"ğğ": x}"#))
        XCTAssertEqual(error.column, 8)
        XCTAssertEqual(error.offset, 7)
    }

    func testRejectsWhatJSONRejects() {
        for bad in ["", "   ", "{a:1}", "[1 2]", "01", "1.", "-", "\"açık", "{\"a\":1}x", "tru", "\"\\x\"", "\"a\nb\"", "/* kapanmamış"] {
            XCTAssertNotNil(issue(bad), bad)
        }
    }

    func testDeepNestingIsAnErrorNotACrash() throws {
        let deep = String(repeating: "[", count: JSONDocument.maxDepth + 10) + String(repeating: "]", count: JSONDocument.maxDepth + 10)
        XCTAssertTrue(try XCTUnwrap(issue(deep)).message.contains("seviye"))
    }
}

final class JSONToolTests: XCTestCase {
    func testFormatUsesTheExistingFormatterAndIndentation() throws {
        XCTAssertEqual(try JSONTool.format(#"{"a":[1,2]}"#, options: .init(indentation: .fourSpaces)),
                       "{\n    \"a\": [\n        1,\n        2\n    ]\n}")
        XCTAssertEqual(try JSONTool.format(#"{"a":1}"#, options: .init(indentation: .tab)), "{\n\t\"a\": 1\n}")
        // API Client'taki Beautify ile birebir aynı çıktı.
        let input = "{\"b\":1, // yorum\n\"a\":[]}"
        XCTAssertEqual(try JSONTool.format(input, options: .init()), try JSONFormatter.beautify(input))
    }

    func testFormatWithSortedKeys() throws {
        XCTAssertEqual(try JSONTool.format(#"{"b":1,"a":2}"#, options: .init(sortKeys: true)), "{\n  \"a\": 2,\n  \"b\": 1\n}")
    }

    func testMinify() throws {
        XCTAssertEqual(try JSONTool.minify("{\n  \"a\": [1, 2], // x\n  \"b\": \"c d\"\n}", sortKeys: false), #"{"a":[1,2],"b":"c d"}"#)
    }

    func testEscapeAndUnescapeRoundTrip() throws {
        // İç JSON'daki `\n` kaçışlı (geçerli JSON); dışarıya gömülünce `\\n` olur.
        let original = #"{"mesaj": "satır\nsonu"}"#
        let escaped = JSONTool.escape(original)
        XCTAssertEqual(escaped, #""{\"mesaj\": \"satır\\nsonu\"}""#)
        // Çözülen metin JSON olduğu için biçimlendirilmiş döner.
        XCTAssertEqual(try JSONTool.unescape(escaped, options: .init()), "{\n  \"mesaj\": \"satır\\nsonu\"\n}")
        // JSON olmayan metin olduğu gibi döner.
        XCTAssertEqual(try JSONTool.unescape(JSONTool.escape("satır\nsonu"), options: .init()), "satır\nsonu")
    }

    func testUnescapeWithoutSurroundingQuotes() throws {
        XCTAssertEqual(try JSONTool.unescape(#"{\"a\":1}"#, options: .init()), "{\n  \"a\": 1\n}")
        XCTAssertEqual(try JSONTool.unescape(#"düz\tmetin"#, options: .init()), "düz\tmetin")
        XCTAssertThrowsError(try JSONTool.unescape(#""\x""#, options: .init()))
    }

    func testUnescapeOnAlreadyPlainJSONJustFormats() throws {
        // Kullanıcının denediği girdi: kaçışsız, geçerli JSON.
        let plain = #"{"musteri": {"ad": "Ali", "tutar": 12345678901234567890}, "hata": 12}"#
        XCTAssertEqual(try JSONTool.unescape(plain, options: .init()), try JSONTool.format(plain, options: .init()))
        XCTAssertEqual(try JSONTool.unescape("[1,2]", options: .init()), "[\n  1,\n  2\n]")
    }

    func testUnescapeExplainsUnescapedQuotes() {
        XCTAssertThrowsError(try JSONTool.unescape(#"{"a": 1, bozuk"#, options: .init())) { error in
            XCTAssertTrue(error.localizedDescription.contains("kaçışlı bir JSON string değil"), error.localizedDescription)
        }
    }

    func testEveryActionReversesItsOutput() throws {
        let options = WorkbenchOptions()
        let plain = #"{"a": "x\ny"}"#
        let escaped = JSONTool.escape(plain)
        // Her eylem kendi tipik girdisiyle: Unescape'in girdisi kaçışlı metin.
        let inputs = ["format": plain, "minify": plain, "escape": plain, "unescape": escaped]
        for action in WorkbenchTools.json.actions {
            let input = try XCTUnwrap(inputs[action.id], action.id)
            let reverse = try XCTUnwrap(action.reverse, action.id)
            let back = try reverse(try action.run(input, options), input, options)
            // Ters dönüşüm girdiyle aynı veriyi üretir (kaçışlı metinde
            // içteki JSON karşılaştırılır; boşluk farkı veri farkı değil).
            XCTAssertEqual(try data(back), try data(input), action.id)
        }
        XCTAssertThrowsError(try JSONTool.decodeLiteral(#""yarım"#))
    }

    private func data(_ text: String) throws -> JSONValue {
        let value = try JSONDocument.parse(text)
        if case .string(let inner) = value, let nested = try? JSONDocument.parse(inner) { return nested }
        return value
    }

    func testUnescapeOnPlainJSONReversesWithoutEscaping() throws {
        // Kaçışsız JSON'a Unescape yalnızca biçimlendirir; çıktı düzenlemesi
        // girdiyi string'e çevirmemeli.
        let plain = #"{"a":1}"#
        XCTAssertEqual(JSONTool.reverseUnescape("{\n  \"a\": 2\n}", previousInput: plain), "{\n  \"a\": 2\n}")
    }

    func testValidate() {
        XCTAssertEqual(JSONTool.validate("  "), .empty)
        XCTAssertEqual(JSONTool.validate(#"{"a":1}"#), .valid)
        guard case .invalid(let issue) = JSONTool.validate("{\"a\":}") else { return XCTFail() }
        XCTAssertEqual(issue.line, 1)
    }
}

final class JSONTreeNodeTests: XCTestCase {
    func testPathsMatchTokenFactorySyntax() throws {
        let root = JSONTreeNode(value: try JSONDocument.parse(#"{"data":{"items":[{"token":"x"}]},"a.b":1}"#))
        let data = try XCTUnwrap(root.children?.first)
        let items = try XCTUnwrap(data.children?.first)
        let first = try XCTUnwrap(items.children?.first)
        let token = try XCTUnwrap(first.children?.first)
        XCTAssertEqual(token.path, "data.items[0].token")
        XCTAssertEqual(token.summary, #""x""#)
        // Token Factory aynı yolu okuyabilmeli.
        XCTAssertEqual(try TokenField.steps(of: token.path), [.key("data"), .key("items"), .index(0), .key("token")])
        XCTAssertEqual(root.children?.last?.path, #"["a.b"]"#)
    }

    func testLargeArraysAreSummarised() throws {
        let items = (0..<(JSONTreeNode.childLimit + 5)).map { _ in JSONValue.null }
        let children = try XCTUnwrap(JSONTreeNode(value: .array(items)).children)
        XCTAssertEqual(children.count, JSONTreeNode.childLimit + 1)
        XCTAssertEqual(children.last?.summary, "… 5 eleman daha")
        XCTAssertNil(children.last?.children)
    }
}

final class WorkbenchCatalogTests: XCTestCase {
    func testSearchIsCaseAndDiacriticInsensitive() {
        let jsonTools = ["json", "json-to-csv", "csv-to-json", "json-to-xml", "xml-to-json", "json-to-yaml"]
        XCTAssertEqual(WorkbenchCatalog.matching("json").map(\.id), jsonTools)
        XCTAssertEqual(WorkbenchCatalog.matching("JSON").map(\.id), jsonTools)
        // Sıkıştıran her araç: Türkçe karakter/harf farkı gözetmeden (Markdown sıkıştırmaz).
        XCTAssertEqual(WorkbenchCatalog.matching("SIKIŞTIR").map(\.id),
                       WorkbenchCatalog.all.filter { $0.actions.contains { $0.id == "minify" } }.map(\.id))
        XCTAssertTrue(WorkbenchCatalog.matching("bicim").map(\.id).contains("json"))
        XCTAssertTrue(WorkbenchCatalog.matching("yok-böyle-araç").isEmpty)
        XCTAssertEqual(WorkbenchCatalog.matching("  ").count, WorkbenchCatalog.all.count)
    }

    func testEveryToolHasAtLeastOneActionAndUniqueIDs() {
        XCTAssertEqual(Set(WorkbenchCatalog.all.map(\.id)).count, WorkbenchCatalog.all.count)
        for tool in WorkbenchCatalog.all {
            XCTAssertFalse(tool.actions.isEmpty, tool.id)
            XCTAssertEqual(Set(tool.actions.map(\.id)).count, tool.actions.count, tool.id)
        }
    }
}

final class TextStatsTests: XCTestCase {
    func testCountsBytesLinesAndCharacters() {
        XCTAssertEqual(TextStats(""), .empty)
        XCTAssertEqual(TextStats("a"), TextStats(bytes: 1, lines: 1, characters: 1))
        // "ğ" iki bayt, bir karakter; "👍🏽" tek karakter.
        XCTAssertEqual(TextStats("ğ\n👍🏽\n"), TextStats(bytes: 12, lines: 3, characters: 4))
        XCTAssertEqual(TextStats("{\n  \"a\": 1\n}").summary, "12 bytes · 3 lines · 12 chars")
        XCTAssertEqual(TextStats.size(1), "1 byte")
        XCTAssertEqual(TextStats.size(1_234), "1.2 KB")
        XCTAssertEqual(TextStats.size(56_789), "57 KB")
        XCTAssertEqual(TextStats.size(5_400_000), "5.4 MB")
        XCTAssertEqual(TextStats(bytes: 1, lines: 1_234, characters: 12_345).summary, "1 byte · 1,234 lines · 12,345 chars")
    }

    func testTreeIsOfferedOnlyForFormat() {
        let actions = WorkbenchTools.json.actions
        XCTAssertEqual(actions.filter(\.supportsTree).map(\.id), ["format"])
    }
}

final class JSONTreeEditTests: XCTestCase {
    private let input = #"{"musteri":{"ad":"Ali","tutar":12345678901234567890,"aktif":true},"etiketler":["a","b"],"not":null}"#

    func testEditingAStringKeepsItAStringWithoutQuotes() throws {
        let result = try JSONTool.replacingValue(in: input, at: [.key("musteri"), .key("ad")], with: "Ayşe 123", options: .init())
        XCTAssertEqual(try JSONDocument.parse(result).value(at: [.key("musteri"), .key("ad")]), .string("Ayşe 123"))
        // Diğer her şey (sıra, büyük sayı) korunur.
        XCTAssertEqual(try JSONDocument.parse(result).value(at: [.key("musteri"), .key("tutar")]), .number("12345678901234567890"))
        XCTAssertTrue(result.hasPrefix("{\n  \"musteri\""))
    }

    func testEditingScalarsUsesJSONSpellingOrFallsBackToString() throws {
        func edit(_ steps: [JSONPathStep], _ text: String) throws -> JSONValue? {
            try JSONDocument.parse(JSONTool.replacingValue(in: input, at: steps, with: text, options: .init())).value(at: steps)
        }
        XCTAssertEqual(try edit([.key("musteri"), .key("tutar")], "123"), .number("123"))
        XCTAssertEqual(try edit([.key("musteri"), .key("aktif")], "false"), .bool(false))
        XCTAssertEqual(try edit([.key("not")], "\"metin\""), .string("metin"))
        XCTAssertEqual(try edit([.key("not")], "düz metin"), .string("düz metin"))
        XCTAssertEqual(try edit([.key("etiketler"), .index(1)], "c"), .string("c"))
        // Nesne/dizi yazılamaz (yapı ağaçtan değişmez): metin olarak kalır.
        XCTAssertEqual(try edit([.key("not")], "{}"), .string("{}"))
    }

    func testMissingPathIsAnError() {
        XCTAssertThrowsError(try JSONTool.replacingValue(in: input, at: [.key("yok")], with: "1", options: .init()))
        XCTAssertThrowsError(try JSONTool.replacingValue(in: input, at: [.key("etiketler"), .index(9)], with: "1", options: .init()))
    }

    func testTreeNodesCarryStepsAndOnlyLeavesAreEditable() throws {
        let root = JSONTreeNode(value: try JSONDocument.parse(#"{"a.b":{"c":[1]}}"#))
        let ab = try XCTUnwrap(root.children?.first)
        XCTAssertEqual(ab.steps, [.key("a.b")])
        XCTAssertFalse(ab.isEditableLeaf)
        let one = try XCTUnwrap(ab.children?.first?.children?.first)
        XCTAssertEqual(one.steps, [.key("a.b"), .key("c"), .index(0)])
        XCTAssertTrue(one.isEditableLeaf)
        XCTAssertEqual(one.editableText, "1")
    }
}

final class JSONTreeNavigationTests: XCTestCase {
    private let root = JSONTreeNode(value: try! JSONDocument.parse(#"{"data":{"items":[{"token":"x"},{"token":"y"}]},"ok":true,"bos":{}}"#))

    func testOnlyExpandedBranchesProduceRows() {
        XCTAssertEqual(root.visibleRows(expanded: []).map(\.id), ["data", "ok", "bos"])
        let rows = root.visibleRows(expanded: ["data", "data.items"])
        XCTAssertEqual(rows.map(\.id), ["data", "data.items", "data.items[0]", "data.items[1]", "ok", "bos"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 2, 0, 0])
    }

    func testExpandAllOpensEveryNonEmptyBranchUpToTheLimit() {
        let all = root.expandableIDs()
        XCTAssertEqual(all.ids, ["data", "data.items", "data.items[0]", "data.items[1]"], "boş nesne açılabilir değil")
        XCTAssertFalse(all.truncated)
        let limited = root.expandableIDs(limit: 2)
        XCTAssertEqual(limited.ids, ["data", "data.items"], "önce üst seviyeler")
        XCTAssertTrue(limited.truncated)
    }

    func testAncestryForBreadcrumb() throws {
        let rows = root.visibleRows(expanded: ["data", "data.items", "data.items[1]"])
        let token = try XCTUnwrap(rows.first { $0.id == "data.items[1].token" }?.node)
        XCTAssertEqual(root.ancestry(to: token).map(\.label), ["data", "items", "[1]", "token"])
        // Girdi değişip düğüm kalmadıysa boş.
        let other = JSONTreeNode(value: try JSONDocument.parse(#"{"data":{}}"#))
        XCTAssertTrue(other.ancestry(to: token).isEmpty)
    }

    func testPrimitiveRootIsASingleRow() throws {
        let scalar = JSONTreeNode(value: try JSONDocument.parse("42"))
        XCTAssertEqual(scalar.visibleRows(expanded: []).count, 1)
        XCTAssertTrue(scalar.expandableIDs().ids.isEmpty)
    }
}
