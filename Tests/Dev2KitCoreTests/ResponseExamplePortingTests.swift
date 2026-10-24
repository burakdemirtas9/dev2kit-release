import XCTest
@testable import Dev2KitCore

/// Örneklerin içe/dışa aktarımı: dev2kit (kendi biçimi), Postman
/// (`item.response`) ve OpenAPI (açıkça yazılmış `example(s)`).
final class ResponseExamplePortingTests: XCTestCase {
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    // MARK: - dev2kit

    func testDev2KitExportIncludesExamplesAndImportRegeneratesIDs() throws {
        var request = RequestModel(name: "Kullanıcı", url: "{{baseUrl}}/users/1")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0xFF])
        request.examples = [
            ResponseExample(name: "200 OK", statusCode: 200, headers: [.init(name: "Content-Type", value: "application/json")],
                            body: #"{"id": 1}"#, contentType: "application/json"),
            ResponseExample(name: "Görsel", statusCode: 200, body: png.base64EncodedString(), bodyEncoding: .base64, contentType: "image/png"),
            ResponseExample(name: "Boş", statusCode: 204),
        ]
        let data = try CollectionPorting.exportData(CollectionModel(name: "API", requests: [request]))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"examples\""))

        let outcome = try CollectionPorting.importDev2Kit(data, existingNames: [])
        let imported = try XCTUnwrap(outcome.collection.requests.first)
        XCTAssertEqual(imported.examples.map(\.name), ["200 OK", "Görsel", "Boş"])
        XCTAssertEqual(imported.examples[1].bodyData, png)
        XCTAssertEqual(imported.examples[0].contentType, "application/json")
        XCTAssertTrue(Set(imported.examples.map(\.id)).isDisjoint(with: request.examples.map(\.id)), "örnek kimlikleri yenilenir")
        XCTAssertEqual(outcome.warnings, [])
    }

    func testDev2KitImportSkipsBrokenExamplesWithReasonAndKeepsTheRest() throws {
        let id = UUID().uuidString
        let json = """
        {"format":"dev2kit-collection","version":1,"collection":{"id":"\(UUID().uuidString)","name":"API","requests":[
          {"id":"\(id)","name":"Liste","method":"GET","url":"https://a.b","examples":[
            {"id":"\(UUID().uuidString)","name":"iyi","statusCode":200,"body":"[]"},
            {"id":"\(UUID().uuidString)","name":"kod","statusCode":1200},
            {"id":"\(UUID().uuidString)","name":"kodsuz"},
            {"id":"\(UUID().uuidString)","name":"bozuk body","statusCode":200,"body":"%%%","bodyEncoding":"base64"},
            {"name":"kimliksiz"}
          ]},
          {"id":"\(UUID().uuidString)","name":"Diğer","method":"POST","url":"https://a.b"}
        ]}}
        """
        let outcome = try CollectionPorting.importDev2Kit(Data(json.utf8), existingNames: [])
        XCTAssertEqual(outcome.collection.requests.count, 2, "geçerli istekler alınır")
        XCTAssertEqual(outcome.collection.requests[0].examples.map(\.name), ["iyi", "kod", "kodsuz"], "status doğrulanmaz")
        XCTAssertEqual(outcome.collection.requests[0].examples.map(\.statusCode), [200, 1200, ResponseExamples.unknownStatus])
        XCTAssertTrue(outcome.warnings.contains { $0.contains("bozuk body") && $0.contains("base64") }, "\(outcome.warnings)")
        XCTAssertTrue(outcome.warnings.contains { $0.contains("okunamadı") }, "\(outcome.warnings)")
    }

    func testDev2KitImportMasksCredentialsInExamples() throws {
        var request = RequestModel(name: "Login")
        request.examples = [ResponseExample(name: "ok", statusCode: 200,
                                            headers: [.init(name: "Set-Cookie", value: "SID=1")],
                                            body: #"{"token": "abc"}"#)]
        let data = try CollectionPorting.exportData(CollectionModel(name: "API", requests: [request]))
        let imported = try CollectionPorting.importDev2Kit(data, existingNames: []).collection.requests[0].examples[0]
        XCTAssertEqual(imported.headers[0].value, HistoryRedactor.mask)
        XCTAssertFalse(imported.body.contains("abc"))
    }

    // MARK: - Postman

    private func postman(responses: String) -> Data {
        Data("""
        {"info":{"name":"PM","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
         "item":[{"name":"Kullanıcı","request":{"method":"GET","url":"https://a.b/u"},"response":[\(responses)]}]}
        """.utf8)
    }

    func testPostmanResponsesBecomeExamples() throws {
        let data = postman(responses: """
        {"name":"Başarılı","code":200,"status":"OK","header":[{"key":"Content-Type","value":"application/json"}],"body":"{\\"id\\":1}"},
        {"name":"Yok","code":"404","header":null,"body":null}
        """)
        let outcome = try CollectionPorting.importPostman(data, existingNames: [])
        let examples = outcome.collection.requests[0].examples
        XCTAssertEqual(examples.map(\.name), ["Başarılı", "Yok"])
        XCTAssertEqual(examples.map(\.statusCode), [200, 404])
        XCTAssertEqual(examples[0].contentType, "application/json")
        XCTAssertEqual(examples[0].body, #"{"id":1}"#)
        XCTAssertEqual(examples[1].body, "")
    }

    func testPostmanExampleWithoutCodeIsImported() throws {
        // Ekran görüntüsündeki durum: kodsuz ve statüsüz Postman örnekleri.
        let data = postman(responses: #"{"name":"New Request","body":"{}"}"#)
        let outcome = try CollectionPorting.importPostman(data, existingNames: [])
        XCTAssertEqual(outcome.collection.requests[0].examples.map(\.name), ["New Request"])
        XCTAssertEqual(outcome.collection.requests[0].examples[0].statusCode, ResponseExamples.unknownStatus)
        XCTAssertEqual(outcome.warnings, [], "status için not düşülmez")
    }

    func testPostmanBrokenExampleIsReportedAndOthersImported() throws {
        let data = postman(responses: """
        {"name":"Kodsuz","status":"Teapot"},
        42,
        {"name":"İyi","code":201,"body":"ok"}
        """)
        let outcome = try CollectionPorting.importPostman(data, existingNames: [])
        XCTAssertEqual(outcome.collection.requests.count, 1)
        XCTAssertEqual(outcome.collection.requests[0].examples.map(\.name), ["Kodsuz", "İyi"], "kodsuz örnek de alınır")
        XCTAssertTrue(outcome.warnings.contains { $0.contains("okunamadı") }, "\(outcome.warnings)")
    }

    func testPostmanOverLimitIsKeptForUserSelection() throws {
        let many = (0..<7).map { #"{"name":"e\#($0)","code":200,"body":""}"# }.joined(separator: ",")
        let outcome = try CollectionPorting.importPostman(postman(responses: many), existingNames: [])
        XCTAssertEqual(outcome.collection.requests[0].examples.count, 7, "fazlalık burada kırpılmaz; kullanıcı seçer")
        XCTAssertEqual(ResponseExamples.overflowingRequests(in: outcome.collection).count, 1)
    }

    // MARK: - OpenAPI

    func testOpenAPIExplicitResponseExamplesAreImported() throws {
        let spec = """
        {"openapi":"3.0.1","info":{"title":"Kullanıcılar","version":"1"},"servers":[{"url":"https://api.example.com"}],
         "paths":{"/users/{id}":{"get":{"summary":"Getir","responses":{
           "200":{"description":"Bulundu","content":{"application/json":{"example":{"id":1,"name":"Ada"}}}},
           "404":{"description":"Yok","content":{"application/json":{"examples":{"missing":{"summary":"Kayıt yok","value":{"error":"not found"}}}}}},
           "500":{"description":"Şemadan","content":{"application/json":{"schema":{"type":"object"}}}},
           "default":{"description":"Diğer","content":{"text/plain":{"example":"x"}}}
         }}}}}
        """
        let document = try OpenAPIImporter.parse(Data(spec.utf8), sourceURL: nil)
        let outcome = try OpenAPIImporter.makeCollection(from: document, variableName: "baseUrl", existingNames: [])
        let examples = try XCTUnwrap(outcome.collection.requests.first).examples
        XCTAssertEqual(examples.map(\.name), ["Bulundu", "Kayıt yok"], "şemadan üretilen değer ve 'default' alınmaz")
        XCTAssertEqual(examples.map(\.statusCode), [200, 404])
        XCTAssertEqual(examples[0].contentType, "application/json")
        XCTAssertTrue(examples[0].body.contains("\"name\" : \"Ada\""), examples[0].body)
    }
}
