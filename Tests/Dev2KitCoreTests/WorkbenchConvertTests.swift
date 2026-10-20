import XCTest
@testable import Dev2KitCore

final class CSVConverterTests: XCTestCase {
    /// Beklenen mesajlar Türkçe.
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    private func csv(_ json: String, _ delimiter: CSVDelimiter = .comma) throws -> String {
        try CSVConverter.fromJSON(json, delimiter: delimiter)
    }

    // MARK: JSON → CSV

    func testArrayOfObjectsUsesFirstSeenColumnOrderAndBlankForMissing() throws {
        XCTAssertEqual(try csv(#"[{"id":1,"ad":"Ali"},{"ad":"Ayşe","yas":30}]"#), "id,ad,yas\n1,Ali,\n,Ayşe,30")
    }

    func testSingleObjectIsOneRow() throws {
        XCTAssertEqual(try csv(#"{"a":1,"b":true,"c":null}"#), "a,b,c\n1,true,")
    }

    func testNestedObjectsBecomeDottedColumnsAndArraysJSONText() throws {
        // Kullanıcı kararı: dizi hücreye JSON metni, satır çoğaltılmaz.
        XCTAssertEqual(try csv(#"[{"adres":{"il":"İzmir","kod":{"posta":"35000"}},"etiket":["a","b"],"bos":{}}]"#),
                       #"adres.il,adres.kod.posta,etiket,bos"# + "\n" + #"İzmir,35000,"[""a"",""b""]",{}"#)
    }

    func testQuotingFollowsRFC4180() throws {
        XCTAssertEqual(try csv(#"[{"a":"x,y","b":"say \"hi\"","c":"1\n2","d":"düz"}]"#),
                       "a,b,c,d\n\"x,y\",\"say \"\"hi\"\"\",\"1\n2\",düz")
        // Ayraç değişince virgül artık tırnak gerektirmez.
        XCTAssertEqual(try csv(#"[{"a":"x,y","b":"p;q"}]"#, .semicolon), "a;b\nx,y;\"p;q\"")
        XCTAssertEqual(try csv(#"[{"a":"x y","b":"t\tu"}]"#, .tab), "a\tb\nx y\t\"t\tu\"")
    }

    func testBigNumbersStayExact() throws {
        XCTAssertEqual(try csv(#"[{"n":12345678901234567890}]"#), "n\n12345678901234567890")
    }

    func testSingleColumnEmptyRowIsQuotedNotDropped() throws {
        // Boş hücre tırnaklı: aksi halde tek sütunda boş satır, satır kaybı olur.
        XCTAssertEqual(try csv(#"[{"a":"x"},{"a":""},{"a":"y"}]"#), "a\nx\n\"\"\ny")
    }

    func testRejectsNonTabularInputWithReason() {
        XCTAssertThrowsError(try csv("[1,2]")) { XCTAssertTrue("\($0.localizedDescription)".contains("[0] sayı")) }
        XCTAssertThrowsError(try csv(#""metin""#)) { XCTAssertTrue("\($0.localizedDescription)".contains("nesne dizisi")) }
        XCTAssertThrowsError(try csv("{bozuk"))
    }

    func testEmptyArrayGivesEmptyOutput() throws {
        XCTAssertEqual(try csv("[]"), "")
        XCTAssertEqual(try csv("[{}]"), "")
    }
}

final class XMLConverterTests: XCTestCase {
    private func xml(_ json: String, root: String = "root") throws -> String {
        try XMLConverter.fromJSON(json, rootName: root, indent: "  ")
    }

    // MARK: JSON → XML

    func testObjectsArraysAndNulls() throws {
        XCTAssertEqual(try xml(#"{"ad":"Ali","kalem":["a","b"],"not":null,"bos":[],"adres":{"il":"İzmir"}}"#), """
        <?xml version="1.0" encoding="UTF-8"?>
        <root>
          <ad>Ali</ad>
          <kalem>a</kalem>
          <kalem>b</kalem>
          <not/>
          <bos/>
          <adres>
            <il>İzmir</il>
          </adres>
        </root>
        """)
    }

    func testRootArrayAndNestedArraysUseItem() throws {
        XCTAssertEqual(try xml("[1,[2,3]]", root: "liste"), """
        <?xml version="1.0" encoding="UTF-8"?>
        <liste>
          <item>1</item>
          <item>
            <item>2</item>
            <item>3</item>
          </item>
        </liste>
        """)
    }

    func testAttributeAndTextKeysBecomeAttributesAndText() throws {
        let text = try xml(##"{"@no":"7","kalem":["a","b"],"fiyat":{"@para":"TRY","#text":"12.50"}}"##, root: "siparis")
        XCTAssertTrue(text.contains(#"<siparis no="7">"#))
        XCTAssertTrue(text.contains(#"<fiyat para="TRY">12.50</fiyat>"#))
        XCTAssertTrue(text.contains("<kalem>a</kalem>") && text.contains("<kalem>b</kalem>"))
    }

    func testEscapesTextAndAttributes() throws {
        let text = try xml(#"{"@a":"x\"<&>\ny","b":"1 < 2 & 3"}"#)
        XCTAssertTrue(text.contains(#"<root a="x&quot;&lt;&amp;&gt;&#10;y">"#))
        XCTAssertTrue(text.contains("<b>1 &lt; 2 &amp; 3</b>"))
        XCTAssertEqual(MarkupTools.validateXML(text), .valid)
    }

    func testInvalidNamesAreMadeSafeAndReported() throws {
        let text = try xml(#"{"first name":1,"1st":2,"ok-name.x":3,"":4,"@":5}"#, root: "my root")
        XCTAssertTrue(text.contains("<my_root>"))
        XCTAssertTrue(text.contains("<first_name>1</first_name>"))
        XCTAssertTrue(text.contains("<_1st>2</_1st>"))
        XCTAssertTrue(text.contains("<ok-name.x>3</ok-name.x>"))
        XCTAssertTrue(text.contains(#"<!-- Renamed (not valid XML names): "my root" → my_root, "first name" → first_name"#))
        XCTAssertEqual(MarkupTools.validateXML(text), .valid)
    }

    func testEmptyRootNameFallsBackToRoot() throws {
        XCTAssertTrue(try xml("1", root: "  ").hasSuffix("<root>1</root>"))
    }

    func testControlCharactersAreAnErrorNotSilentlyDropped() {
        XCTAssertThrowsError(try xml(#"{"a":"x\u0001"}"#)) { XCTAssertTrue("\($0.localizedDescription)".contains("U+0001")) }
    }
}

final class YAMLWriterTests: XCTestCase {
    private func yaml(_ json: String) throws -> String { try YAMLWriter.fromJSON(json) }

    func testBlockStyle() throws {
        XCTAssertEqual(try yaml(#"{"server":{"port":8080,"ssl":true},"profiles":["dev","prod"],"items":[{"a":1,"b":null},[1,2]],"bos":{},"liste":[]}"#), """
        server:
          port: 8080
          ssl: true
        profiles:
          - dev
          - prod
        items:
          - a: 1
            b: null
          - - 1
            - 2
        bos: {}
        liste: []
        """)
    }

    func testAmbiguousStringsAreQuoted() throws {
        // "Norway problemi" ve YAML 1.1 sayı/tarih okumaları.
        for text in ["no", "NO", "on", "yes", "y", "null", "~", "true", "012", "1e3", "2024-01-01", "+1", ".5", "-x",
                     "", " a", "a ", "a: b", "a #c", "key:", "#c", "*ref", "&a", "!tag", "|", ">", "@x", "`x`", "'x'", "\"x\"",
                     "satır\nsatır", "tab\tx", "[a]", "{a}", "%x", "?x", ",x", "<<"] {
            XCTAssertTrue(YAMLWriter.needsQuotes(text), "\(text.debugDescription) tırnaklanmalı")
        }
        for text in ["Ali", "İzmir", "a:b", "a#b", "http://x.y/z?q=1", "dev-01", "x.y", "noon"] {
            XCTAssertFalse(YAMLWriter.needsQuotes(text), "\(text.debugDescription) düz kalabilir")
        }
        XCTAssertEqual(try yaml(#"{"country":"no","zip":"012","multi":"a\nb","yes":1}"#),
                       "country: \"no\"\nzip: \"012\"\nmulti: \"a\\nb\"\n\"yes\": 1")
    }

    func testScalarRootsAndBigNumbers() throws {
        XCTAssertEqual(try yaml("12345678901234567890"), "12345678901234567890")
        XCTAssertEqual(try yaml(#""no""#), "\"no\"")
        XCTAssertEqual(try yaml("[]"), "[]")
    }
}

final class WorkbenchConvertCatalogTests: XCTestCase {
    /// Beklenen mesajlar İngilizce.
    override func invokeTest() { withLanguage(.english) { super.invokeTest() } }

    func testConvertersAreSeparateToolsUnderConvert() {
        let ids = WorkbenchCatalog.all.filter { $0.category == .convert }.map(\.id)
        // Kullanıcı kararı (2026-10-20): CSV → JSON ve XML → JSON kalktı, YAML ↔
        // Properties son iki eleman.
        XCTAssertEqual(ids, ["json-to-csv", "json-to-xml", "json-to-yaml", "yaml-to-properties", "properties-to-yaml"])
        XCTAssertEqual(WorkbenchCatalog.matching("excel").map(\.id), ["json-to-csv"])
        XCTAssertEqual(WorkbenchCatalog.matching("yml").map(\.id), ["json-to-yaml", "yaml-to-properties", "properties-to-yaml"])
    }

    func testObjectConverterCategory() {
        let ids = WorkbenchCatalog.all.filter { $0.category == .objects }.map(\.id)
        XCTAssertEqual(ids, ["json-to-java", "json-to-kotlin", "json-to-swift", "json-to-ts-interface", "json-to-ts-type", "json-to-python"])
        XCTAssertEqual(WorkbenchTool.Category.objects.title, "Object Converter")
        XCTAssertEqual(WorkbenchCatalog.matching("lombok").map(\.id), ["json-to-java"])
        for tool in WorkbenchCatalog.all where tool.category == .objects {
            XCTAssertNoThrow(try tool.actions[0].run(tool.sampleInput, tool.defaultOptions), tool.id)
        }
    }

    func testConvertersHaveNoReverseOrTree() {
        for tool in WorkbenchCatalog.all where tool.category == .convert {
            XCTAssertNil(tool.actions[0].reverse, tool.id)
            XCTAssertFalse(tool.actions[0].supportsTree, tool.id)
        }
        XCTAssertEqual(WorkbenchTools.propertiesToYAML.inputName, "Properties")
    }
}
