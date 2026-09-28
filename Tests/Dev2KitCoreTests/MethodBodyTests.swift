import XCTest
@testable import Dev2KitCore

/// GET + gövde: URLSession bunu göndermiyor (bkz. `HTTPMethod.allowsBody`).
/// İstek ağa çıkmadan, anlaşılır bir hatayla durdurulmalı.
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

    func testGetWithRawBodyIsRejectedBeforeSending() {
        let request = model(.get, body: .raw(content: #"{"a":1}"#, contentType: "application/json"))
        XCTAssertThrowsError(try engine.buildURLRequest(request, resolver: resolver)) { error in
            guard case RequestEngineError.bodyNotAllowed(.get) = error else {
                return XCTFail("beklenen hata değil: \(error)")
            }
            // Sistem hatası ("kaynak en fazla büyüklüğü aşıyor") yerine ne
            // yapılacağını söyleyen bir mesaj gelmeli.
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("POST"), message)
        }
    }

    func testGetWithFormBodyIsAlsoRejected() {
        let request = model(.get, body: .formURLEncoded(fields: [KeyValueEntry(key: "a", value: "1")]))
        XCTAssertThrowsError(try engine.buildURLRequest(request, resolver: resolver))
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

/// İçe aktarma tarafı: curl gövdeli GET gönderebiliyor, biz gönderemiyoruz.
/// İstek yine de aktarılır; kullanıcı sınırı gönderirken değil ŞİMDİ öğrenir.
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
