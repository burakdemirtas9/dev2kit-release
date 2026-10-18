import XCTest
@testable import Dev2KitCore

final class CSVConverterTests: XCTestCase {
    private func csv(_ json: String, _ delimiter: CSVDelimiter = .comma) throws -> String {
        try CSVConverter.fromJSON(json, delimiter: delimiter)
    }

    private func json(_ csv: String, detectTypes: Bool = true) throws -> JSONValue {
        try JSONDocument.parse(CSVConverter.toJSON(csv, detectTypes: detectTypes, indent: "  "))
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

    func testSingleColumnEmptyRowSurvivesRoundTrip() throws {
        let text = try csv(#"[{"a":"x"},{"a":""},{"a":"y"}]"#)
        XCTAssertEqual(text, "a\nx\n\"\"\ny")
        XCTAssertEqual(try json(text, detectTypes: false), try JSONDocument.parse(#"[{"a":"x"},{"a":""},{"a":"y"}]"#))
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

    // MARK: CSV → JSON

    func testHeaderRowAndDetectedTypes() throws {
        XCTAssertEqual(try json("id,ad,aktif,not\n1,Ali,true,\n2.5,Ayşe,false,null"),
                       try JSONDocument.parse(#"[{"id":1,"ad":"Ali","aktif":true,"not":null},{"id":2.5,"ad":"Ayşe","aktif":false,"not":null}]"#))
    }

    func testDetectTypesKeepsIdentifierLikeValuesAsText() throws {
        // Posta kodu, telefon, kart numarası, yerel ondalık: metin kalır.
        let value = try json("a,b,c,d,e,f\n012,+90555,1234567890123456,\"1,5\",.5,1e3")
        XCTAssertEqual(value, try JSONDocument.parse(#"[{"a":"012","b":"+90555","c":"1234567890123456","d":"1,5","e":".5","f":1e3}]"#))
    }

    func testDetectTypesOffKeepsEverythingText() throws {
        XCTAssertEqual(try json("a,b,c\n1,true,", detectTypes: false), try JSONDocument.parse(#"[{"a":"1","b":"true","c":""}]"#))
    }

    func testDottedHeadersNestUnlessAnotherHeaderIsAPrefix() throws {
        XCTAssertEqual(try json("adres.il,adres.ilce,ad\nİzmir,Bornova,Ali"),
                       try JSONDocument.parse(#"[{"adres":{"il":"İzmir","ilce":"Bornova"},"ad":"Ali"}]"#))
        XCTAssertEqual(try json("a,a.b,.x,y.\n1,2,3,4"),
                       try JSONDocument.parse(#"[{"a":1,"a.b":2,".x":3,"y.":4}]"#))
    }

    func testRoundTripThroughCSVKeepsStructure() throws {
        let original = #"[{"id":1,"adres":{"il":"İzmir"},"etiket":["a","b"],"not":null,"aktif":true}]"#
        XCTAssertEqual(try json(try csv(original)), try JSONDocument.parse(original))
    }

    func testDelimiterIsDetectedFromHeader() throws {
        XCTAssertEqual(CSVConverter.detectDelimiter("a;b;c\n1,5;2;3"), .semicolon)
        XCTAssertEqual(CSVConverter.detectDelimiter("a\tb\n1\t2"), .tab)
        XCTAssertEqual(CSVConverter.detectDelimiter("\"x;y\",b\n1,2"), .comma)
        XCTAssertEqual(CSVConverter.detectDelimiter("tek"), .comma)
        XCTAssertEqual(try json("a;b\n\"1,5\";x"), try JSONDocument.parse(#"[{"a":"1,5","b":"x"}]"#))
    }

    func testQuotedFieldsWithNewlinesQuotesAndCRLF() throws {
        XCTAssertEqual(try json("a,b\r\n\"satır1\r\nsatır2\",\"say \"\"hi\"\"\"\r\n"),
                       try JSONDocument.parse(#"[{"a":"satır1\r\nsatır2","b":"say \"hi\""}]"#))
    }

    func testRaggedRowsBlankLinesBOMAndHeaderFixes() throws {
        XCTAssertEqual(try json("\u{FEFF}ad,,ad\n\nAli,x,y,fazla\nAyşe\n"),
                       try JSONDocument.parse(#"[{"ad":"Ali","column2":"x","ad_2":"y","column4":"fazla"},{"ad":"Ayşe","column2":null,"ad_2":null}]"#))
    }

    func testHeaderOnlyGivesEmptyArray() throws {
        XCTAssertEqual(try json("a,b"), .array([]))
    }

    func testUnclosedQuoteIsReportedWithPosition() {
        guard case .invalid(let issue) = CSVConverter.validate("a,b\n1,\"açık") else { return XCTFail() }
        XCTAssertEqual(issue.line, 2)
        XCTAssertEqual(issue.column, 3)
        XCTAssertEqual(CSVConverter.validate("a,b\n1,2"), .valid)
    }

    func testArrayCellsBecomeValuesOnlyWhenValidJSON() throws {
        XCTAssertEqual(try json("a,b\n\"[1,2]\",[bozuk"), try JSONDocument.parse(#"[{"a":[1,2],"b":"[bozuk"}]"#))
    }
}

final class XMLConverterTests: XCTestCase {
    private func json(_ xml: String, detectTypes: Bool = false) throws -> JSONValue {
        try JSONDocument.parse(XMLConverter.toJSON(xml, detectTypes: detectTypes, indent: "  "))
    }

    private func xml(_ json: String, root: String = "root") throws -> String {
        try XMLConverter.fromJSON(json, rootName: root, indent: "  ")
    }

    // MARK: XML → JSON

    func testAttributesTextAndRepeatedSiblings() throws {
        let value = try json(#"<siparis no="7" durum="acik"><kalem>a</kalem><kalem>b</kalem><not/></siparis>"#)
        XCTAssertEqual(value, try JSONDocument.parse(#"{"siparis":{"@durum":"acik","@no":"7","kalem":["a","b"],"not":""}}"#))
    }

    func testTextNextToAttributesGoesToHashText() throws {
        XCTAssertEqual(try json(#"<fiyat para="TRY">12.50</fiyat>"#),
                       try JSONDocument.parse(##"{"fiyat":{"@para":"TRY","#text":"12.50"}}"##))
    }

    func testIndentationWhitespaceIsNotDataAndCDATAIsText() throws {
        XCTAssertEqual(try json("<a>\n  <b>\n    x\n  </b>\n  <c><![CDATA[<raw> & ]]></c>\n</a>"),
                       try JSONDocument.parse(#"{"a":{"b":"x","c":"<raw> &"}}"#))
    }

    func testDetectTypesIsOptIn() throws {
        XCTAssertEqual(try json("<a><n>12</n><b>true</b><z>012</z></a>"),
                       try JSONDocument.parse(#"{"a":{"n":"12","b":"true","z":"012"}}"#))
        XCTAssertEqual(try json("<a><n>12</n><b>true</b><z>012</z></a>", detectTypes: true),
                       try JSONDocument.parse(#"{"a":{"n":12,"b":true,"z":"012"}}"#))
        XCTAssertFalse(WorkbenchTools.xmlToJSON.defaultOptions.detectTypes, "XML'de varsayılan kapalı")
        XCTAssertTrue(WorkbenchTools.csvToJSON.defaultOptions.detectTypes, "CSV'de varsayılan açık")
    }

    func testNamespacedNamesAreKeptAsWritten() throws {
        let value = try json(#"<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><x>1</x></soap:Body></soap:Envelope>"#)
        XCTAssertEqual(value, try JSONDocument.parse(#"{"soap:Envelope":{"@xmlns:soap":"http://schemas.xmlsoap.org/soap/envelope/","soap:Body":{"x":"1"}}}"#))
    }

    func testInvalidXMLReportsPosition() {
        XCTAssertThrowsError(try json("<a>\n<b></a>")) { error in
            XCTAssertEqual((error as? WorkbenchIssue)?.line, 2)
        }
    }

    func testExternalEntitiesAreNotResolved() throws {
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-xxe-\(UUID()).txt")
        try "GIZLI".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        let input = "<!DOCTYPE a [<!ENTITY x SYSTEM \"\(secret.absoluteString)\">]><a>&x;</a>"
        let output = (try? XMLConverter.toJSON(input, detectTypes: false, indent: "  ")) ?? ""
        XCTAssertFalse(output.contains("GIZLI"))
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

    func testAttributeAndTextKeysRoundTrip() throws {
        let original = ##"{"siparis":{"@no":"7","kalem":["a","b"],"fiyat":{"@para":"TRY","#text":"12.50"}}}"##
        let text = try xml(##"{"@no":"7","kalem":["a","b"],"fiyat":{"@para":"TRY","#text":"12.50"}}"##, root: "siparis")
        XCTAssertTrue(text.contains(#"<siparis no="7">"#))
        XCTAssertTrue(text.contains(#"<fiyat para="TRY">12.50</fiyat>"#))
        XCTAssertEqual(try json(text), try JSONDocument.parse(original))
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
    func testConvertersAreSeparateToolsUnderConvert() {
        let ids = WorkbenchCatalog.all.filter { $0.category == .convert }.map(\.id)
        XCTAssertEqual(ids, ["json-to-csv", "csv-to-json", "json-to-xml", "xml-to-json", "json-to-yaml"])
        XCTAssertEqual(WorkbenchCatalog.matching("excel").map(\.id), ["json-to-csv", "csv-to-json"])
        XCTAssertEqual(WorkbenchCatalog.matching("yml").map(\.id), ["json-to-yaml"])
        XCTAssertTrue(WorkbenchCatalog.matching("dönüştür").count == 5)
    }

    func testConvertersHaveNoReverseOrTree() {
        for tool in WorkbenchCatalog.all where tool.category == .convert {
            XCTAssertNil(tool.actions[0].reverse, tool.id)
            XCTAssertFalse(tool.actions[0].supportsTree, tool.id)
        }
        XCTAssertEqual(WorkbenchTools.csvToJSON.inputName, "CSV")
    }
}
