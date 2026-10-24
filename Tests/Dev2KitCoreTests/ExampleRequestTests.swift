import XCTest
@testable import Dev2KitCore

/// Örneğin request tarafı (Postman `originalRequest`), düzenleme kuralı ve
/// Postman v2.1 dışa/içe aktarımı.
final class ExampleRequestTests: XCTestCase {
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    private func sentRequest() -> RequestModel {
        RequestModel(
            name: "Kullanıcı",
            method: .post,
            url: "{{baseUrl}}/users?expand=roles&api_key=abc123",
            headers: [KeyValueEntry(key: "Authorization", value: "Bearer eyJhbGciOi"),
                      KeyValueEntry(key: "X-Token", value: "{{secret:token}}"),
                      KeyValueEntry(key: "Accept", value: "application/json")],
            queryParams: [KeyValueEntry(key: "expand", value: "roles"), KeyValueEntry(key: "api_key", value: "abc123")],
            body: .raw(content: #"{"name": "Ada", "password": "s3cret"}"#, contentType: "application/json")
        )
    }

    // MARK: - Anlık görüntü

    func testCaptureStoresMaskedTemplateRequest() throws {
        let response = ResponseData(statusCode: 201, headers: [("Content-Type", "application/json")],
                                    body: Data("{}".utf8), duration: 0, finalURL: nil)
        let example = try ResponseExamples.capture(response, request: sentRequest(), name: "Oluşturuldu")
        let request = try XCTUnwrap(example.request)
        XCTAssertEqual(request.method, .post)
        XCTAssertTrue(request.url.hasPrefix("{{baseUrl}}/users?expand=roles"), "değişken çözülmez")
        XCTAssertFalse(request.url.contains("abc123"), "query'deki anahtar maskeli: \(request.url)")
        XCTAssertEqual(request.headers.first { $0.key == "Authorization" }?.value, HistoryRedactor.mask)
        XCTAssertEqual(request.headers.first { $0.key == "X-Token" }?.value, "{{secret:token}}", "referans olduğu gibi")
        XCTAssertEqual(request.headers.first { $0.key == "Accept" }?.value, "application/json")
        guard case .raw(let content, _) = request.body else { return XCTFail("raw body") }
        XCTAssertFalse(content.contains("s3cret"))
        XCTAssertTrue(content.contains("Ada"))
    }

    func testOldExampleWithoutRequestOrHeaderIDsDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"eski","statusCode":200,"headers":[{"name":"A","value":"1"}],"body":"x"}"#
        let example = try JSONDecoder().decode(ResponseExample.self, from: Data(json.utf8))
        XCTAssertNil(example.request, "uydurulmaz")
        XCTAssertEqual(example.headers.first?.name, "A")
        XCTAssertEqual(example.headers.first?.enabled, true)
    }

    func testExampleWithRequestRoundTrips() throws {
        var example = ResponseExample(name: "e", statusCode: 200, body: "{}")
        example.request = ExampleRequest(capturing: sentRequest())
        let data = try JSONEncoder().encode(example)
        XCTAssertEqual(try JSONDecoder().decode(ResponseExample.self, from: data), example)
    }

    // MARK: - Düzenleme

    func testEditNormalization() {
        let previous = ResponseExample(name: "ad", statusCode: 200, headers: [.init(name: "Content-Type", value: "text/plain")],
                                       body: "x", contentType: "text/plain")
        var edited = previous
        edited.name = "  "
        edited.headers[0].value = "application/json"
        let normalized = ResponseExamples.normalizedAfterEdit(edited, previous: previous)
        XCTAssertEqual(normalized.name, "ad", "boş ad öncekine döner")
        XCTAssertEqual(normalized.contentType, "application/json", "Content-Type header'dan")

        var disabled = edited
        disabled.headers[0].enabled = false
        XCTAssertNil(ResponseExamples.normalizedAfterEdit(disabled, previous: previous).contentType, "kapalı header sayılmaz")
        XCTAssertTrue(disabled.responseData.headers.isEmpty, "kapalı header gösterimde de yok")

        let binary = ResponseExample(name: "png", statusCode: 200, body: Data([0xFF, 0x00]).base64EncodedString(), bodyEncoding: .base64)
        var tampered = binary
        tampered.body = "metin"
        XCTAssertEqual(ResponseExamples.normalizedAfterEdit(tampered, previous: binary).body, binary.body, "ikili body korunur")
    }

    // MARK: - Postman

    func testPostmanOriginalRequestIsImported() throws {
        let json = """
        {"info":{"name":"PM","schema":"\(PostmanExporter.schemaURL)"},
         "item":[{"name":"Kullanıcı","request":{"method":"GET","url":"https://a.b/u"},
           "response":[{"name":"Bulundu","code":200,"status":"OK",
             "originalRequest":{"method":"POST","url":{"raw":"https://a.b/u?q=1"},
               "header":[{"key":"X-Trace","value":"t1"}],
               "body":{"mode":"raw","raw":"{\\"a\\":1}","options":{"raw":{"language":"json"}}}},
             "header":[{"key":"Content-Type","value":"application/json"},{"key":"X-Off","value":"1","disabled":true}],
             "body":"{}"}]}]}
        """
        let outcome = try CollectionPorting.importPostman(Data(json.utf8), existingNames: [])
        let example = try XCTUnwrap(outcome.collection.requests.first?.examples.first)
        let request = try XCTUnwrap(example.request)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url, "https://a.b/u?q=1")
        XCTAssertEqual(request.headers.map(\.key), ["X-Trace"])
        XCTAssertEqual(request.body, .raw(content: #"{"a":1}"#, contentType: "application/json"))
        XCTAssertEqual(example.headers.first { $0.name == "X-Off" }?.enabled, false, "kapalı header korunur")
    }

    func testPostmanExportRoundTripsRequestsAndExamples() throws {
        var request = RequestModel(
            name: "Oluştur", method: .post, url: "{{baseUrl}}/users",
            headers: [KeyValueEntry(key: "Accept", value: "application/json"), KeyValueEntry(key: "X-Off", value: "1", enabled: false)],
            body: .raw(content: #"{"name": "Ada"}"#, contentType: "application/json"),
            auth: .bearer(token: "{{secret:api}}")
        )
        request.examples = [
            ResponseExample(name: "Oluşturuldu", statusCode: 201,
                            headers: [.init(name: "Content-Type", value: "application/json")],
                            body: #"{"id": 7}"#, contentType: "application/json",
                            request: ExampleRequest(method: .post, url: "{{baseUrl}}/users",
                                                    headers: [KeyValueEntry(key: "Accept", value: "application/json")],
                                                    body: .raw(content: #"{"name": "Ada"}"#, contentType: "application/json"))),
            ResponseExample(name: "Request'siz", statusCode: 400, body: "hata"),
        ]
        let form = RequestModel(name: "Form", method: .put, url: "https://a.b/f",
                                body: .formURLEncoded(fields: [KeyValueEntry(key: "a", value: "1")]),
                                auth: .apiKey(key: "X-Key", value: "{{secret:k}}", location: .header))
        let output = try PostmanExporter.export(CollectionModel(name: "API", requests: [request, form]))
        XCTAssertEqual(output.notes, [])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        XCTAssertEqual((root["info"] as? [String: Any])?["schema"] as? String, PostmanExporter.schemaURL)

        let back = try CollectionPorting.importPostman(output.data, existingNames: []).collection
        XCTAssertEqual(back.name, "API")
        XCTAssertEqual(back.requests.count, 2)
        let first = back.requests[0]
        XCTAssertEqual(first.method, .post)
        XCTAssertEqual(first.url, "{{baseUrl}}/users")
        XCTAssertEqual(first.headers.map(\.key), ["Accept", "X-Off"])
        XCTAssertEqual(first.headers.map(\.enabled), [true, false])
        XCTAssertEqual(first.body, request.body)
        XCTAssertEqual(first.auth, .bearer(token: "{{secret:api}}"), "secret referansı çözülmeden")
        XCTAssertEqual(first.examples.map(\.name), ["Oluşturuldu", "Request'siz"])
        XCTAssertEqual(first.examples[0].statusCode, 201)
        XCTAssertEqual(first.examples[0].body, #"{"id": 7}"#)
        XCTAssertEqual(first.examples[0].request?.method, .post)
        XCTAssertEqual(first.examples[0].request?.body, request.examples[0].request?.body)
        XCTAssertNil(first.examples[1].request)
        guard case .formURLEncoded(let fields) = back.requests[1].body else { return XCTFail("form body") }
        XCTAssertEqual(fields.map { [$0.key, $0.value] }, [["a", "1"]], "alan kimlikleri içe aktarmada yenilenir")
        XCTAssertEqual(back.requests[1].auth, form.auth)
    }

    func testPostmanExportReportsWhatCannotBeCarried() throws {
        var request = RequestModel(name: "OAuth", url: "https://a.b?x=1",
                                   queryParams: [KeyValueEntry(key: "x", value: "1"), KeyValueEntry(key: "kapali", value: "2", enabled: false)],
                                   auth: .oauth2(OAuth2Config()), options: RequestOptions(timeout: 5))
        request.examples = [ResponseExample(name: "png", statusCode: 200, body: Data([0xFF]).base64EncodedString(), bodyEncoding: .base64)]
        let notes = try PostmanExporter.export(CollectionModel(name: "API", requests: [request])).notes
        XCTAssertEqual(notes.count, 4, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("OAuth2") })
        XCTAssertTrue(notes.contains { $0.contains("OAuth › png") })
    }

    func testPostmanExportKeepsUnusualRawContentTypeAsHeader() throws {
        let request = RequestModel(name: "YAML", method: .post, url: "https://a.b",
                                   body: .raw(content: "a: 1", contentType: "application/x-yaml"))
        let back = try CollectionPorting.importPostman(
            try PostmanExporter.export(CollectionModel(name: "API", requests: [request])).data, existingNames: []
        ).collection.requests[0]
        XCTAssertEqual(back.headers.first { $0.key == "Content-Type" }?.value, "application/x-yaml")
    }
}
