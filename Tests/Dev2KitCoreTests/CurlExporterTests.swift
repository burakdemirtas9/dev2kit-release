import XCTest
@testable import Dev2KitCore

final class CurlExporterTests: XCTestCase {
    private let secrets = InMemorySecretStore(initial: ["token": "gizli123"])

    func testSimpleGet() throws {
        let model = RequestModel(method: .get, url: "https://api.example.com/users")
        let curl = try CurlExporter.export(model, environment: nil, secretStore: secrets)
        XCTAssertEqual(curl, "curl -X GET 'https://api.example.com/users'")
    }

    func testSecretsKeptAsPlaceholderByDefault() throws {
        var model = RequestModel(url: "https://api.example.com")
        model.auth = .bearer(token: "{{secret:token}}")
        let curl = try CurlExporter.export(model, environment: nil, secretStore: secrets)
        XCTAssertTrue(curl.contains("Authorization: Bearer {{secret:token}}"))
        XCTAssertFalse(curl.contains("gizli123"))
    }

    func testSecretsResolvedWhenRequested() throws {
        var model = RequestModel(url: "https://api.example.com")
        model.auth = .bearer(token: "{{secret:token}}")
        let curl = try CurlExporter.export(model, environment: nil, secretStore: secrets, includeSecrets: true)
        XCTAssertTrue(curl.contains("Authorization: Bearer gizli123"))
    }

    func testBasicAuthUsesUserFlag() throws {
        var model = RequestModel(url: "https://api.example.com")
        model.auth = .basic(username: "ali", password: "sifre")
        let curl = try CurlExporter.export(model, environment: nil, secretStore: secrets)
        XCTAssertTrue(curl.contains("-u 'ali:sifre'"))
        XCTAssertFalse(curl.contains("Authorization"))
    }

    func testRawBodyAndContentType() throws {
        var model = RequestModel(method: .post, url: "https://api.example.com")
        model.body = .raw(content: #"{"a":1}"#, contentType: "application/json")
        let curl = try CurlExporter.export(model, environment: nil, secretStore: secrets)
        XCTAssertTrue(curl.contains(#"--data-raw '{"a":1}'"#))
        XCTAssertTrue(curl.contains("-H 'Content-Type: application/json'"))
        XCTAssertFalse(curl.contains("Content-Length"))
    }

    /// Uygulamanın gönderdiği kodlanmış gövdenin aynısı, `--data-raw` ile
    /// (`--data-urlencode` adda `@` görünce dosya okurdu; F2).
    func testFormURLEncodedUsesTheEncodedBodyAsDataRaw() throws {
        var model = RequestModel(method: .post, url: "https://api.example.com")
        model.body = .formURLEncoded(fields: [
            KeyValueEntry(key: "ad", value: "büyük değer"),
            KeyValueEntry(key: "kapali", value: "x", enabled: false),
        ])
        let curl = try CurlExporter.export(model, environment: nil, secretStore: secrets)
        XCTAssertTrue(curl.contains("--data-raw 'ad=b%C3%BCy%C3%BCk%20de%C4%9Fer'"), curl)
        XCTAssertFalse(curl.contains("--data-urlencode"))
        XCTAssertFalse(curl.contains("kapali"))
    }

    /// `--form-string`: değer her zaman düz metin (`-F` `@`/`<` ile dosya okurdu; F2).
    func testMultipartUsesFormStringWithoutContentTypeHeader() throws {
        var model = RequestModel(method: .post, url: "https://api.example.com")
        model.body = .multipartForm(fields: [KeyValueEntry(key: "alan", value: "deger")])
        let curl = try CurlExporter.export(model, environment: nil, secretStore: secrets)
        XCTAssertTrue(curl.contains("--form-string 'alan=deger'"), curl)
        XCTAssertFalse(curl.contains("-F "))
        XCTAssertFalse(curl.contains("Content-Type"), "curl boundary'yi kendisi üretmeli")
    }

    func testSingleQuoteEscaping() throws {
        var model = RequestModel(method: .post, url: "https://api.example.com")
        model.body = .raw(content: "tek'tirnak", contentType: "text/plain")
        let curl = try CurlExporter.export(model, environment: nil, secretStore: secrets)
        XCTAssertTrue(curl.contains(#"--data-raw 'tek'\''tirnak'"#))
    }

    func testEnvironmentVariableResolvedInURL() throws {
        let environment = EnvironmentModel(name: "test", variables: [
            KeyValueEntry(key: "baseUrl", value: "https://api.example.com")
        ])
        let model = RequestModel(url: "{{baseUrl}}/v1")
        let curl = try CurlExporter.export(model, environment: environment, secretStore: secrets)
        XCTAssertTrue(curl.contains("'https://api.example.com/v1'"))
    }
}
