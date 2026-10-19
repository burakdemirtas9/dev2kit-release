import XCTest
@testable import Dev2KitCore

/// Gövdedeki yorumlar yalnızca kullanıcı için, gönderilmez (2026-10-20).
final class RequestBodyCommentsTests: XCTestCase {
    private func send(_ text: String, _ type: String = "application/json") -> String {
        RequestBodyComments.sendable(text, contentType: type)
    }

    func testCommentLinesAndTrailingCommentsAreRemoved() {
        let body = """
        {
          // müşteri kimliği
          "id": 42, // sabit
          /* çok
             satırlı */
          "url": "https://ornek.test/a//b",
          "not": "/* metin, yorum değil */"
        }
        """
        XCTAssertEqual(send(body), """
        {
          "id": 42,
          "url": "https://ornek.test/a//b",
          "not": "/* metin, yorum değil */"
        }
        """)
    }

    func testCommentingOutTheLastFieldLeavesValidJSON() throws {
        let body = """
        {
          "a": 1,
          // "b": 2
        }
        """
        let sent = send(body)
        XCTAssertEqual(sent, "{\n  \"a\": 1\n}")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(sent.utf8)))
        XCTAssertEqual(send("[\n  1,\n  /* 2 */\n]"), "[\n  1\n]")
    }

    func testUntouchedWithoutCommentsOrForOtherTypes() {
        let plain = "{\n  \"a\": [1, 2,],\n  \"u\": \"x/y\"\n}"
        XCTAssertEqual(send(plain), plain, "yorum yoksa bayt bayt aynı (sondaki virgüle de dokunulmaz)")
        let xml = "<a><!-- not --><b>1</b></a>"
        XCTAssertEqual(send(xml, "application/xml"), xml)
        XCTAssertEqual(send("// js değil\nmetin", "text/plain"), "// js değil\nmetin")
        XCTAssertTrue(RequestBodyComments.appliesTo(contentType: "application/vnd.api+json"))
    }

    func testEngineAndCurlSendWithoutComments() throws {
        let secrets = InMemorySecretStore()
        let resolver = VariableResolver(environment: nil, secretStore: secrets)
        // Yorumdaki tanımsız değişken isteği durdurmamalı.
        let model = RequestModel(method: .post, url: "https://api.example.com/x",
                                 body: .raw(content: "{\n  // {{tanimsiz}}\n  \"a\": 1\n}", contentType: "application/json"))
        let built = try RequestEngine().buildURLRequest(model, resolver: resolver)
        XCTAssertEqual(built.httpBody, Data("{\n  \"a\": 1\n}".utf8))
        XCTAssertFalse(SecretReferences.variableNames(in: model, environment: nil).contains("tanimsiz"))
        let curl = try CurlExporter.export(model, environment: nil, secretStore: secrets)
        XCTAssertFalse(curl.contains("tanimsiz"), "cURL de gönderilenle aynı")
    }
}
