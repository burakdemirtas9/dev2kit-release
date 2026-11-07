import XCTest
@testable import Dev2KitCore

/// Endpoint'in örnek request body'si (kullanıcı isteği, 2026-11-07):
/// eşleşmeyi etkilemez, cURL olarak güvenle kopyalanır.
final class MockRequestExampleTests: XCTestCase {
    func testCurlIsSafelyQuoted() {
        let command = MockRequestExample.curl(method: .post, baseURL: "http://localhost:8098",
                                              path: "/bnpl-service/execute-payment/pay",
                                              body: #"{"note": "it's"}"#)
        let expected = [
            "curl \\",
            "  -X POST 'http://localhost:8098/bnpl-service/execute-payment/pay' \\",
            "  -H 'Content-Type: application/json' \\",
            #"  --data-raw '{"note": "it'\''s"}'"#,
        ].joined(separator: "\n")
        XCTAssertEqual(command, expected)
    }

    func testBodyNeverReadsAFileAndPatternsAreLiteral() {
        let command = MockRequestExample.curl(method: .any, baseURL: "http://localhost:8099/", path: "/orders/{id}", body: "@/etc/passwd")
        XCTAssertTrue(command.contains("--data-raw '@/etc/passwd'"), "gövde dosya okumaz")
        XCTAssertTrue(command.contains("--globoff"), "{id} desen sanılmaz")
        XCTAssertTrue(command.contains("-X POST 'http://localhost:8099/orders/{id}'"), "Any + gövde → POST")
        XCTAssertFalse(command.contains("Content-Type"), "JSON değilse tür eklenmez")
    }

    func testEmptyBodyWithAnyIsGet() {
        XCTAssertEqual(MockRequestExample.curl(method: .any, baseURL: "http://localhost:8098", path: "/a", body: " "),
                       "curl \\\n  -X GET 'http://localhost:8098/a'")
        XCTAssertTrue(MockRequestExample.curl(method: .delete, baseURL: "http://localhost:8098", path: "a", body: "")
            .contains("-X DELETE 'http://localhost:8098/a'"), "yol / ile başlamasa da")
    }

    func testExampleDoesNotAffectMatching() {
        let endpoint = MockEndpoint(method: .post, path: "/pay", requestBody: #"{"amount": 1}"#)
        let route = MockRouter.route(MockIncomingRequest(method: "POST", target: "/pay", body: Data("başka".utf8)), endpoints: [endpoint])
        XCTAssertEqual(route.outcome, .defaultResponse)
    }

    func testOldFilesWithoutExampleStillDecode() throws {
        let json = #"{"endpoints":[{"path":"/a"}]}"#
        let document = try JSONDecoder().decode(MockerDocument.self, from: Data(json.utf8))
        XCTAssertEqual(document.endpoints.first?.requestBody, "")
    }
}
