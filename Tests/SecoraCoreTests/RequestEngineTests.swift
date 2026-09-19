import XCTest
@testable import SecoraCore

final class RequestEngineTests: XCTestCase {
    private let engine = RequestEngine()

    private func resolver(
        variables: [String: String] = [:],
        secrets: [String: String] = [:]
    ) -> VariableResolver {
        let environment = EnvironmentModel(
            name: "test",
            variables: variables.map { KeyValueEntry(key: $0.key, value: $0.value) }
        )
        return VariableResolver(environment: environment, secretStore: InMemorySecretStore(initial: secrets))
    }

    func testBuildsBasicGetRequest() throws {
        let model = RequestModel(method: .get, url: "https://api.example.com/users")
        let request = try engine.buildURLRequest(model, resolver: resolver())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/users")
        XCTAssertNil(request.httpBody)
    }

    func testInvalidURLThrows() {
        let model = RequestModel(url: "bu bir url değil")
        XCTAssertThrowsError(try engine.buildURLRequest(model, resolver: resolver()))
    }

    func testQueryParamsAppended() throws {
        let model = RequestModel(
            url: "https://api.example.com/search?q=eski",
            queryParams: [
                KeyValueEntry(key: "limit", value: "10"),
                KeyValueEntry(key: "kapali", value: "x", enabled: false),
            ]
        )
        let request = try engine.buildURLRequest(model, resolver: resolver())
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.count, 2)
        XCTAssertTrue(query!.contains(URLQueryItem(name: "q", value: "eski")))
        XCTAssertTrue(query!.contains(URLQueryItem(name: "limit", value: "10")))
    }

    func testBearerAuthResolvesSecret() throws {
        var model = RequestModel(url: "https://api.example.com")
        model.auth = .bearer(token: "{{secret:token}}")
        let request = try engine.buildURLRequest(model, resolver: resolver(secrets: ["token": "abc123"]))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
    }

    func testBasicAuthEncoding() throws {
        var model = RequestModel(url: "https://api.example.com")
        model.auth = .basic(username: "user", password: "pass")
        let request = try engine.buildURLRequest(model, resolver: resolver())
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic \(Data("user:pass".utf8).base64EncodedString())"
        )
    }

    func testApiKeyInQueryParam() throws {
        var model = RequestModel(url: "https://api.example.com/data")
        model.auth = .apiKey(key: "api_key", value: "{{secret:k}}", location: .queryParam)
        let request = try engine.buildURLRequest(model, resolver: resolver(secrets: ["k": "v1"]))
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query!.contains(URLQueryItem(name: "api_key", value: "v1")))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testBodySetsContentType() throws {
        var model = RequestModel(method: .post, url: "https://api.example.com")
        model.body = .raw(content: #"{"a":1}"#, contentType: "application/json")
        let request = try engine.buildURLRequest(model, resolver: resolver())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, Data(#"{"a":1}"#.utf8))
    }

    func testExplicitContentTypeHeaderWins() throws {
        var model = RequestModel(method: .post, url: "https://api.example.com")
        model.headers = [KeyValueEntry(key: "Content-Type", value: "text/plain")]
        model.body = .raw(content: "x", contentType: "application/json")
        let request = try engine.buildURLRequest(model, resolver: resolver())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
    }

    func testGetBodySentViaStream() throws {
        // URLSession GET'te httpBody'yi düşürdüğü için stream kullanılır.
        var model = RequestModel(method: .get, url: "https://api.example.com")
        model.body = .raw(content: "sorgu", contentType: "text/plain")
        let request = try engine.buildURLRequest(model, resolver: resolver())
        XCTAssertNil(request.httpBody)
        XCTAssertNotNil(request.httpBodyStream)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "\(Data("sorgu".utf8).count)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
    }

    func testFormURLEncodedBody() throws {
        var model = RequestModel(method: .post, url: "https://api.example.com")
        model.body = .formURLEncoded(fields: [
            KeyValueEntry(key: "ad", value: "büyük değer"),
            KeyValueEntry(key: "token", value: "{{secret:t}}"),
            KeyValueEntry(key: "kapali", value: "x", enabled: false),
        ])
        let request = try engine.buildURLRequest(model, resolver: resolver(secrets: ["t": "abc"]))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("token=abc"))
        XCTAssertFalse(body.contains("kapali"))
        XCTAssertFalse(body.contains(" "), "boşluklar percent-encode edilmeli")
    }

    func testMultipartFormBody() throws {
        var model = RequestModel(method: .post, url: "https://api.example.com")
        model.body = .multipartForm(fields: [
            KeyValueEntry(key: "alan", value: "değer {{secret:t}}"),
        ])
        let request = try engine.buildURLRequest(model, resolver: resolver(secrets: ["t": "abc"]))
        let contentType = request.value(forHTTPHeaderField: "Content-Type")!
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = contentType.components(separatedBy: "boundary=")[1]
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("--\(boundary)\r\n"))
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"alan\""))
        XCTAssertTrue(body.contains("değer abc\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
    }

    func testEmptyFormBodyNotAttached() throws {
        var model = RequestModel(method: .post, url: "https://api.example.com")
        model.body = .formURLEncoded(fields: [KeyValueEntry(key: "", value: "x")])
        let request = try engine.buildURLRequest(model, resolver: resolver())
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
    }

    func testEmptyBodyNotAttached() throws {
        var model = RequestModel(method: .post, url: "https://api.example.com")
        model.body = .raw(content: "", contentType: "application/json")
        let request = try engine.buildURLRequest(model, resolver: resolver())
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
    }

    func testVariableInURLResolved() throws {
        let model = RequestModel(url: "{{baseUrl}}/users")
        let request = try engine.buildURLRequest(
            model,
            resolver: resolver(variables: ["baseUrl": "https://api.example.com"])
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/users")
    }
}
