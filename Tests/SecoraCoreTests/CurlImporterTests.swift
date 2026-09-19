import XCTest
@testable import SecoraCore

final class ShellTokenizerTests: XCTestCase {
    func testSplitsOnWhitespace() throws {
        XCTAssertEqual(try ShellTokenizer.tokenize("curl -X GET url"), ["curl", "-X", "GET", "url"])
    }

    func testSingleQuotesArePreservedLiterally() throws {
        XCTAssertEqual(
            try ShellTokenizer.tokenize(#"curl -d '{"a": "b c"}'"#),
            ["curl", "-d", #"{"a": "b c"}"#]
        )
    }

    func testDoubleQuotesHandleEscapes() throws {
        XCTAssertEqual(
            try ShellTokenizer.tokenize(#"curl -d "{\"a\":1}""#),
            ["curl", "-d", #"{"a":1}"#]
        )
    }

    func testLineContinuationIsSkipped() throws {
        let command = """
        curl 'https://a.example.com' \\
          -H 'Accept: application/json'
        """
        XCTAssertEqual(
            try ShellTokenizer.tokenize(command),
            ["curl", "https://a.example.com", "-H", "Accept: application/json"]
        )
    }

    func testANSIQuotingDecodesEscapes() throws {
        // Chrome "Copy as cURL" Türkçe/özel karakterlerde bu biçimi üretir.
        XCTAssertEqual(try ShellTokenizer.tokenize(#"curl -d $'sat\nır'"#), ["curl", "-d", "sat\nır"])
    }

    func testEmptyQuotedArgumentKept() throws {
        XCTAssertEqual(try ShellTokenizer.tokenize("curl -d ''"), ["curl", "-d", ""])
    }

    func testUnclosedQuoteThrows() {
        XCTAssertThrowsError(try ShellTokenizer.tokenize("curl -d 'açık"))
        XCTAssertThrowsError(try ShellTokenizer.tokenize(#"curl -d "açık"#))
    }
}

final class CurlImporterTests: XCTestCase {
    func testSimpleGet() throws {
        let result = try CurlImporter.parse("curl https://api.example.com/users")
        XCTAssertEqual(result.request.method, .get)
        XCTAssertEqual(result.request.url, "https://api.example.com/users")
    }

    func testWorksWithoutCurlPrefix() throws {
        let result = try CurlImporter.parse("https://api.example.com/users -H 'Accept: application/json'")
        XCTAssertEqual(result.request.url, "https://api.example.com/users")
        XCTAssertEqual(result.request.headers.first?.key, "Accept")
    }

    func testExplicitMethodWins() throws {
        let result = try CurlImporter.parse("curl -X DELETE https://api.example.com/users/1")
        XCTAssertEqual(result.request.method, .delete)
    }

    func testBodyImpliesPost() throws {
        let result = try CurlImporter.parse(#"curl https://api.example.com -d '{"a":1}'"#)
        XCTAssertEqual(result.request.method, .post)
        if case .raw(let content, let contentType) = result.request.body {
            XCTAssertEqual(content, #"{"a":1}"#)
            XCTAssertEqual(contentType, "application/json")
        } else {
            XCTFail("raw JSON body bekleniyordu")
        }
    }

    func testFormPairsBecomeURLEncodedBody() throws {
        let result = try CurlImporter.parse("curl https://api.example.com -d 'ad=ali&yas=30'")
        guard case .formURLEncoded(let fields) = result.request.body else {
            return XCTFail("urlencoded body bekleniyordu")
        }
        XCTAssertEqual(fields.map(\.key), ["ad", "yas"])
        XCTAssertEqual(fields.map(\.value), ["ali", "30"])
    }

    func testMultipleDataFlagsAreJoined() throws {
        let result = try CurlImporter.parse("curl https://a.example.com -d 'a=1' -d 'b=2'")
        guard case .formURLEncoded(let fields) = result.request.body else {
            return XCTFail("urlencoded body bekleniyordu")
        }
        XCTAssertEqual(fields.count, 2)
    }

    func testMultipartForm() throws {
        let result = try CurlImporter.parse("curl https://a.example.com -F 'ad=ali' -F 'rol=admin'")
        guard case .multipartForm(let fields) = result.request.body else {
            return XCTFail("multipart body bekleniyordu")
        }
        XCTAssertEqual(fields.map(\.key), ["ad", "rol"])
    }

    func testFileUploadFieldWarnsAndSkips() throws {
        let result = try CurlImporter.parse("curl https://a.example.com -F 'dosya=@/tmp/x.png' -F 'ad=ali'")
        guard case .multipartForm(let fields) = result.request.body else {
            return XCTFail("multipart body bekleniyordu")
        }
        XCTAssertEqual(fields.map(\.key), ["ad"])
        XCTAssertTrue(result.warnings.contains { $0.contains("dosya") })
    }

    func testBearerHeaderMovesToAuth() throws {
        let result = try CurlImporter.parse("curl https://a.example.com -H 'Authorization: Bearer abc123'")
        XCTAssertEqual(result.request.auth, .bearer(token: "abc123"))
        XCTAssertFalse(result.request.headers.contains { $0.key.lowercased() == "authorization" })
        XCTAssertTrue(result.warnings.contains { $0.contains("kimlik bilgisi") })
    }

    func testBasicAuthHeaderIsDecoded() throws {
        let encoded = Data("ali:sifre".utf8).base64EncodedString()
        let result = try CurlImporter.parse("curl https://a.example.com -H 'Authorization: Basic \(encoded)'")
        XCTAssertEqual(result.request.auth, .basic(username: "ali", password: "sifre"))
    }

    func testUserFlagBecomesBasicAuth() throws {
        let result = try CurlImporter.parse("curl https://a.example.com -u ali:sifre")
        XCTAssertEqual(result.request.auth, .basic(username: "ali", password: "sifre"))
    }

    func testUnknownAuthSchemeStaysAsHeader() throws {
        let result = try CurlImporter.parse("curl https://a.example.com -H 'Authorization: Negotiate xyz'")
        XCTAssertEqual(result.request.auth, .none)
        XCTAssertTrue(result.request.headers.contains { $0.key == "Authorization" })
    }

    func testCookieFlagBecomesHeader() throws {
        let result = try CurlImporter.parse("curl https://a.example.com -b 'session=abc'")
        XCTAssertTrue(result.request.headers.contains { $0.key == "Cookie" && $0.value == "session=abc" })
    }

    func testRedirectFlags() throws {
        let result = try CurlImporter.parse("curl -L --max-redirs 3 https://a.example.com")
        XCTAssertTrue(result.request.options.redirect.follow)
        XCTAssertEqual(result.request.options.redirect.maxRedirects, 3)
    }

    func testTimeoutFlag() throws {
        let result = try CurlImporter.parse("curl --max-time 12 https://a.example.com")
        XCTAssertEqual(result.request.options.timeout, 12)
    }

    func testEqualsFormFlagSupported() throws {
        let result = try CurlImporter.parse("curl --url=https://a.example.com --max-time=8")
        XCTAssertEqual(result.request.url, "https://a.example.com")
        XCTAssertEqual(result.request.options.timeout, 8)
    }

    func testGetFlagMovesDataToQuery() throws {
        let result = try CurlImporter.parse("curl -G https://a.example.com -d 'q=test&limit=10'")
        XCTAssertEqual(result.request.method, .get)
        XCTAssertEqual(result.request.queryParams.map(\.key), ["q", "limit"])
        XCTAssertEqual(result.request.body, .none)
    }

    func testInsecureFlagIsRefusedLoudly() throws {
        let result = try CurlImporter.parse("curl -k https://a.example.com")
        XCTAssertTrue(result.warnings.contains { $0.contains("TLS") })
    }

    func testClientCertificateFlagWarns() throws {
        let result = try CurlImporter.parse("curl --cert /tmp/c.pem https://a.example.com")
        XCTAssertTrue(result.warnings.contains { $0.contains("sertifika") })
    }

    func testSchemelessURLGetsHTTPS() throws {
        let result = try CurlImporter.parse("curl api.example.com/users")
        XCTAssertEqual(result.request.url, "https://api.example.com/users")
    }

    func testQueryStringInURLPreserved() throws {
        let result = try CurlImporter.parse("curl 'https://a.example.com/s?q=1&p=2'")
        XCTAssertEqual(result.request.url, "https://a.example.com/s?q=1&p=2")
    }

    func testMissingURLThrows() {
        XCTAssertThrowsError(try CurlImporter.parse("curl -X POST -H 'Accept: */*'"))
    }

    func testMissingFlagValueThrows() {
        XCTAssertThrowsError(try CurlImporter.parse("curl https://a.example.com -H"))
    }

    func testChromeStyleCommand() throws {
        // Chrome DevTools "Copy as cURL" tipik çıktısı.
        let command = """
        curl 'https://api.example.com/v1/items' \\
          -H 'accept: application/json' \\
          -H 'content-type: application/json' \\
          -H 'authorization: Bearer eyJhbGciOi' \\
          --data-raw $'{"ad":"K\\u00fcrk"}' \\
          --compressed
        """
        let result = try CurlImporter.parse(command)
        XCTAssertEqual(result.request.method, .post)
        XCTAssertEqual(result.request.url, "https://api.example.com/v1/items")
        XCTAssertEqual(result.request.auth, .bearer(token: "eyJhbGciOi"))
        guard case .raw(let content, _) = result.request.body else {
            return XCTFail("raw body bekleniyordu")
        }
        XCTAssertTrue(content.contains("Kürk"))
    }

    func testRoundtripWithCurlExporter() throws {
        var original = RequestModel(method: .post, url: "https://api.example.com/x")
        original.headers = [KeyValueEntry(key: "X-Trace", value: "1")]
        original.body = .raw(content: #"{"a":1}"#, contentType: "application/json")
        let command = try CurlExporter.export(original, environment: nil, secretStore: InMemorySecretStore())

        let imported = try CurlImporter.parse(command).request
        XCTAssertEqual(imported.method, original.method)
        XCTAssertEqual(imported.url, original.url)
        XCTAssertTrue(imported.headers.contains { $0.key == "X-Trace" && $0.value == "1" })
        if case .raw(let content, _) = imported.body {
            XCTAssertEqual(content, #"{"a":1}"#)
        } else {
            XCTFail("raw body bekleniyordu")
        }
    }
}
