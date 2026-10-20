import XCTest
@testable import Dev2KitCore

/// GET + gövde: URLSession gövdeli GET'i göndermiyor (bkz. `HTTPMethod.allowsBody`).
/// İstek gövdesiz gönderilir, gövde editörde (modelde) korunur, yanıtta
/// bildirim çıkar (kullanıcı isteği, 2026-10-20; eskiden hatayla duruyordu).
final class MethodBodyTests: XCTestCase {
    private let engine = RequestEngine()

    private var resolver: VariableResolver {
        VariableResolver(environment: nil, secretStore: InMemorySecretStore())
    }

    private func model(_ method: HTTPMethod, body: RequestBody) -> RequestModel {
        RequestModel(method: method, url: "https://api.example.com/ara", body: body)
    }

    // MARK: - Kural

    func testOnlyGetRejectsBody() {
        // Ölçümle eşleşmeli: yalnızca GET reddediliyor.
        XCTAssertFalse(HTTPMethod.get.allowsBody)
        for method in HTTPMethod.allCases where method != .get {
            XCTAssertTrue(method.allowsBody, "\(method.rawValue) gövde taşıyabilmeli")
        }
    }

    // MARK: - Motor

    func testGetWithRawBodyIsSentWithoutBody() throws {
        let request = model(.get, body: .raw(content: #"{"a":1}"#, contentType: "application/json"))
        let built = try engine.buildRequest(request, resolver: resolver)
        XCTAssertNil(built.request.httpBody)
        XCTAssertNil(built.request.httpBodyStream)
        XCTAssertNil(built.request.value(forHTTPHeaderField: "Content-Type"), "gövdesiz istekte gövde türü eklenmez")
        XCTAssertTrue(built.omittedBody)
    }

    /// Gönderilmeyen gövde doğrulanmaz, değişkenleri çözülmez: bozuk JSON ve
    /// tanımsız {{değişken}} isteği durdurmaz.
    func testGetSkipsInvalidJSONAndUndefinedVariablesInBody() throws {
        let request = model(.get, body: .raw(content: #"{"a": {{tanimsiz}}, bozuk"#, contentType: "application/json"))
        let built = try engine.buildRequest(request, resolver: resolver)
        XCTAssertNil(built.request.httpBody)
        XCTAssertTrue(built.omittedBody)
    }

    func testGetWithFormBodyIsAlsoOmitted() throws {
        let request = model(.get, body: .formURLEncoded(fields: [KeyValueEntry(key: "a", value: "1")]))
        let built = try engine.buildRequest(request, resolver: resolver)
        XCTAssertNil(built.request.httpBody)
        XCTAssertTrue(built.omittedBody)
    }

    /// Boş, yalnızca boşluk ya da yalnızca yorum: bildirim yok.
    func testEmptyBodiesDoNotReportOmission() throws {
        let empties: [RequestBody] = [
            .none,
            .raw(content: "", contentType: "application/json"),
            .raw(content: "  \n ", contentType: "application/json"),
            .raw(content: "// yalnızca not", contentType: "application/json"),
            .formURLEncoded(fields: [KeyValueEntry(key: "a", value: "1", enabled: false)]),
        ]
        for body in empties {
            XCTAssertFalse(try engine.buildRequest(model(.get, body: body), resolver: resolver).omittedBody, "\(body)")
        }
    }

    /// Gövde modelden silinmez: metot POST'a dönünce aynı gövde gider.
    func testBodyIsPreservedAndSentAfterSwitchingToPost() throws {
        var request = model(.get, body: .raw(content: #"{"a":1}"#, contentType: "application/json"))
        _ = try engine.buildRequest(request, resolver: resolver)
        XCTAssertEqual(request.body, .raw(content: #"{"a":1}"#, contentType: "application/json"))

        request.method = .post
        let built = try engine.buildRequest(request, resolver: resolver)
        XCTAssertEqual(built.request.httpBody, Data(#"{"a":1}"#.utf8))
        XCTAssertFalse(built.omittedBody)
    }

    /// GET gövdesindeki değişken token istemez ve tanımsız sayılmaz.
    func testVariableScanIgnoresGetBody() {
        let get = model(.get, body: .raw(content: #"{"t":"{{token}}"}"#, contentType: "application/json"))
        XCTAssertFalse(SecretReferences.variableNames(in: get, environment: nil).contains("token"))
        var post = get
        post.method = .post
        XCTAssertTrue(SecretReferences.variableNames(in: post, environment: nil).contains("token"))
    }

    func testGetWithEmptyBodyStillWorks() throws {
        // Boş gövde hiç bağlanmıyor; normal bir GET engellenmemeli.
        let request = model(.get, body: .raw(content: "", contentType: "application/json"))
        let built = try engine.buildURLRequest(request, resolver: resolver)
        XCTAssertNil(built.httpBody)
    }

    func testGetWithoutBodyIsUntouched() throws {
        let built = try engine.buildURLRequest(model(.get, body: .none), resolver: resolver)
        XCTAssertNil(built.httpBody)
    }

    /// Eskiden bu metotlarda `httpBodyStream` kullanılıyordu; ölçüm düz
    /// `httpBody` ile gövdenin telde gittiğini gösterdi.
    func testHeadAndOptionsCarryBodyThroughHTTPBody() throws {
        for method in [HTTPMethod.head, .options, .delete] {
            let request = model(method, body: .raw(content: #"{"a":1}"#, contentType: "application/json"))
            let built = try engine.buildURLRequest(request, resolver: resolver)
            XCTAssertEqual(built.httpBody, Data(#"{"a":1}"#.utf8), "\(method.rawValue)")
            XCTAssertNil(built.httpBodyStream, "\(method.rawValue) stream kullanmamalı")
        }
    }

    func testPostBodyUnchanged() throws {
        let request = model(.post, body: .raw(content: #"{"a":1}"#, contentType: "application/json"))
        let built = try engine.buildURLRequest(request, resolver: resolver)
        XCTAssertEqual(built.httpBody, Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(built.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
}

/// İçe aktarma tarafı: curl gövdeli GET gönderebiliyor, biz gövdesiz gönderiyoruz.
/// İstek yine de aktarılır; kullanıcı bunu gönderirken değil ŞİMDİ öğrenir.
extension MethodBodyTests {
    func testCurlImportWarnsAboutGetBody() throws {
        let command = """
        curl -X GET 'https://httpbin.org/get' \
          -H 'Content-Type: application/json' \
          --data-raw '{"a": 1}'
        """
        let result = try CurlImporter.parse(command)
        XCTAssertEqual(result.request.method, .get)
        // Gövde korunur: kullanıcı metodu POST yapıp gönderebilsin.
        XCTAssertEqual(result.request.body, .raw(content: #"{"a": 1}"#, contentType: "application/json"))
        XCTAssertTrue(
            result.warnings.contains { $0.contains("POST") },
            "uyarı bekleniyordu: \(result.warnings)"
        )
    }

    func testCurlImportDoesNotWarnForPostBody() throws {
        let result = try CurlImporter.parse("curl -X POST 'https://a.example' --data-raw '{\"a\":1}'")
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
    }
}
