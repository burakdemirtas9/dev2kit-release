import XCTest
@testable import Dev2KitCore

final class CurlExtractorTests: XCTestCase {
    func testFindsCommandsInsideProseWithContinuationsAndPrompts() {
        let text = """
        Öncelikle token alın. Örnek:
        $ curl -X POST https://api.example.com/v1/token \\
          -H 'Content-Type: application/json' \\
          -d '{"user": "ada"}'
        Sonra listeyi çekin: curl https://api.example.com/v1/items -H "Accept: application/json"
        Bu cümlede curling geçiyor ama komut değil; libcurl de değil.
        """
        let commands = CurlExtractor.commands(in: text)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0], #"curl -X POST https://api.example.com/v1/token -H 'Content-Type: application/json' -d '{"user": "ada"}'"#)
        XCTAssertEqual(commands[1], #"curl https://api.example.com/v1/items -H "Accept: application/json""#)
    }

    func testMultiLineQuotedBodyKeepsItsNewlines() {
        let text = "curl -X POST https://api.example.com/v1/items -d '{\n  \"a\": 1\n}'\nsonraki paragraf"
        XCTAssertEqual(CurlExtractor.commands(in: text), ["curl -X POST https://api.example.com/v1/items -d '{\n  \"a\": 1\n}'"])
    }

    func testWindowsAndPowerShellContinuations() {
        XCTAssertEqual(CurlExtractor.commands(in: "curl https://a.example.com ^\n  -H \"X: 1\""), [#"curl https://a.example.com -H "X: 1""#])
        XCTAssertEqual(CurlExtractor.commands(in: "curl https://a.example.com `\n  -H \"X: 1\""), [#"curl https://a.example.com -H "X: 1""#])
    }

    func testPDFTypographyIsNormalized() {
        // PDF/Word metni: kıvrık tırnak ve uzun tire.
        let text = "curl \u{2013}H \u{201C}Accept: application/json\u{201D} https://a.example.com"
        XCTAssertEqual(CurlExtractor.commands(in: text), [#"curl --H "Accept: application/json" https://a.example.com"#])
    }
}

final class AutoImportTests: XCTestCase {
    private let postman = #"{"info": {"name": "Ödeme API", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"}, "item": []}"#
    private let kibana = #"{"_index": "test-incoming-log-2026.10.19", "_id": "a1", "_source": {"http_method": "GET", "request_path": "/v1/x", "service_name": "svc"}}"#

    func testCurlCommandsBecomeNamedRequests() {
        let found = AutoImport.scan("""
        curl -X POST https://api.example.com/v1/orders -H 'Content-Type: application/json' -d '{"id": 1}'
        curl https://api.example.com/v1/orders/1
        """)
        XCTAssertEqual(found.curl.map(\.request.name), ["POST /v1/orders", "GET /v1/orders/1"])
        XCTAssertEqual(found.curl[0].request.method, .post)
        XCTAssertTrue(found.collections.isEmpty, "cURL gövdesindeki JSON koleksiyon sayılmaz")
    }

    func testUnparseableCommandsAreSkipped() {
        XCTAssertEqual(AutoImport.scan("curl 'açık tırnak\ncurl https://a.example.com/ok").curl.map(\.request.name), ["GET /ok"])
    }

    func testRecognizesWholeTextJSONByContent() throws {
        XCTAssertEqual(AutoImport.scan(postman).collections.map(\.name), ["Ödeme API"])
        XCTAssertEqual(AutoImport.scan(#"{"collection": \#(postman)}"#).collections.first?.kind, .postman)

        let dev2kit = try String(decoding: CollectionPorting.exportData(CollectionModel(name: "K", requests: [])), as: UTF8.self)
        let found = AutoImport.scan(dev2kit)
        XCTAssertEqual(found.collections.first?.kind, .dev2kit)
        XCTAssertEqual(found.collections.first?.name, "K")

        XCTAssertNotNil(AutoImport.scan(#"{"openapi": "3.0.1", "paths": {}}"#).openAPI)
        XCTAssertNotNil(AutoImport.scan(#"{"swagger": "2.0", "paths": {}}"#).openAPI)
        XCTAssertEqual(AutoImport.scan(kibana).kibanaDocuments.count, 1)
        XCTAssertEqual(AutoImport.scan("[\(kibana), \(kibana)]").kibanaDocuments.count, 2)
        XCTAssertEqual(AutoImport.scan(#"{"hits": {"hits": [\#(kibana)]}}"#).kibanaDocuments.count, 1)
        XCTAssertNotNil(AutoImport.scan(#"{"a": 1}"#).emptyReason)
    }

    /// Kullanıcı isteği (2026-10-19): belgede cURL dışında koleksiyon ve
    /// Kibana kaydı da bulunsun.
    func testDocumentWithEverythingEmbedded() throws {
        let document = """
        Entegrasyon Notları
        1) Sağlık kontrolü: curl https://api.example.com/v1/health
        2) Postman koleksiyonu aşağıda:
        \(postman)
        3) Hata anındaki Kibana kaydı:
        \(kibana)
        Not: {kapanmamış parantez ve "tırnak} içeren düzyazı.
        """
        let found = AutoImport.scan(document)
        XCTAssertEqual(found.curl.map(\.request.name), ["GET /v1/health"])
        XCTAssertEqual(found.collections.map(\.name), ["Ödeme API"])
        XCTAssertEqual(found.kibanaDocuments.count, 1)
        // Kibana ekranına giden JSON gerçekten okunabiliyor.
        XCTAssertNoThrow(try KibanaImporter.parse(Data(try XCTUnwrap(found.kibanaJSON).utf8)))
    }

    func testSeveralKibanaRecordsAreCombinedForTheirScreen() throws {
        let found = AutoImport.scan("Kayıt A:\n\(kibana)\nKayıt B:\n\(kibana.replacingOccurrences(of: "a1", with: "b2"))")
        XCTAssertEqual(found.kibanaDocuments.count, 2)
        XCTAssertEqual(try KibanaImporter.parse(Data(try XCTUnwrap(found.kibanaJSON).utf8)).entries.count, 2)
    }

    func testNothingFoundExplainsWhy() {
        XCTAssertTrue(AutoImport.scan("sadece düz bir metin").emptyReason?.contains("cURL") == true)
        XCTAssertNotNil(AutoImport.scan("   ").emptyReason)
    }

    func testCommandCountIsCapped() {
        XCTAssertEqual(AutoImport.scan(String(repeating: "curl https://a.example.com/x\n", count: 500)).curl.count, AutoImport.maxCurlCommands)
    }

    func testUnclosedBracesInProseStayFast() {
        // En kötü durum: binlerce kapanmamış "{" (her biri sona kadar taranabilir).
        let text = String(repeating: "{ açık ", count: 200_000)
        let start = Date()
        _ = AutoImport.scan(text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "tarama bütçesi sınırlamalı")
    }
}

/// Kullanıcının dosyası (2026-10-19): resimden OCR ile çıkarılıp PDF'e
/// dönüştürülmüş Kibana logu. Uzun satırlar kesik/sarılmış, kapanış satırları
/// tekrar etmiş ya da kaybolmuş. Veriler SAHTE; gerçek dosya teste girmez.
final class DamagedKibanaTests: XCTestCase {
    /// Kesik ve sarılmış ama yapısı sağlam: toleranslı okuma yeterli.
    func testClippedAndWrappedLinesAreRepaired() {
        let text = """
        {
        "_index": "test-incoming-log-2026.10.11-000913",
        "_source": {
        "response_body": "{\\"success\\":true,\\"data\\":{\\"a\\":nu
        "http_method": "POST",
        "request_path": "/svc/v1/area",
        "service_name": "finance-sahte-bff-service",
        "headers": {
        "x-o-id":
        "AAAABBBBCCCCDDDD
        EEEEFFFF==",
        "accept": "application/json"
        }
        }
        }
        """
        let found = AutoImport.scan(text)
        XCTAssertEqual(found.kibanaDocuments.count, 1)
        XCTAssertFalse(found.recoveredFromDamagedText, "toleranslı JSON okuması yetti")
        XCTAssertEqual(found.truncatedFields, ["response_body"])
    }

    /// OCR yapıyı bozmuş (tekrar eden ve eksik kapanışlar): alan alan kurtarma.
    func testStructurallyBrokenRecordIsRecoveredFieldByField() throws {
        let text = """
        {
        "_index": "test-incoming-log-2026.10.11-000913",
        "_source": {
        "http_method": "POST",
        "request_path": "/svc/v1/area?x=1",
        "service_name": "finance-sahte-bff-service",
        "request_body": "{\\"amount\\":10}",
        "headers": {
        "x-token": "eyJhbGciOiJIUzI1NiJ9.ZZZZ
        "accept": "application/json",
        "x-o-id":
        "AAAABBBB
        CCCCDDDD==",
        "x-partner": "sahte"
        },
        "fields": {
        "id": [
        "1"
        ],
        ],
        "status": [
        "200"
        "http_method": [
        "POST"
        ]
        }
        }
        """
        let found = AutoImport.scan(text)
        XCTAssertTrue(found.recoveredFromDamagedText)
        XCTAssertEqual(found.truncatedFields, ["headers.x-token"])
        let result = try KibanaImporter.parse(Data(try XCTUnwrap(found.kibanaJSON).utf8))
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.method, .post)
        XCTAssertEqual(entry.path, "/svc/v1/area")
        XCTAssertEqual(entry.serviceName, "finance-sahte-bff-service")
        XCTAssertEqual(entry.body, #"{"amount":10}"#)
        let headers = Dictionary(uniqueKeysWithValues: entry.headers.map { ($0.name, $0.value) })
        XCTAssertEqual(headers["x-o-id"], "AAAABBBBCCCCDDDD==", "sarılmış token birleştirilir")
        XCTAssertEqual(headers["accept"], "application/json")
        XCTAssertEqual(headers["x-partner"], "sahte")
    }

    func testRecoveryNeedsTheEssentialFields() {
        XCTAssertTrue(AutoImport.scan(#"{"_index": "test-x", bozuk"#).kibanaDocuments.isEmpty, "request_path yoksa kayıt kurulmaz")
    }
}
