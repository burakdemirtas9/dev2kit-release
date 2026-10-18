import XCTest
@testable import Dev2KitCore

/// Headers sekmesindeki sayı (kullanıcı kararı, 2026-10-18).
final class HeaderCountTests: XCTestCase {
    func testCountsOnlyEnabledNamedHeaders() {
        var request = RequestModel(name: "r", method: .post, url: "https://a.example.com")
        request.headers = [
            KeyValueEntry(key: "Accept", value: "application/json"),
            KeyValueEntry(key: "X-Kapali", value: "1", enabled: false),
            KeyValueEntry(key: "   ", value: "adsız"),
            KeyValueEntry(key: "X-Trace", value: ""),
        ]
        // Motorun eklediği başlıklar tabloda yok: gövde ve Auth sayıyı değiştirmez.
        request.body = .raw(content: "{}", contentType: "application/json")
        request.auth = .bearer(token: "{{secret:t}}")
        XCTAssertEqual(request.activeHeaderCount, 2)
        XCTAssertEqual(RequestModel(name: "boş", method: .get, url: "").activeHeaderCount, 0)
    }

    func testQueryCountUsesTheSameRule() {
        var request = RequestModel(name: "r", method: .get, url: "https://a.example.com/u?name=xyz")
        request.queryParams = [
            KeyValueEntry(key: "name", value: "xyz"),
            KeyValueEntry(key: "page", value: "2", enabled: false),
            KeyValueEntry(key: "", value: "yarım"),
        ]
        XCTAssertEqual(request.activeQueryParamCount, 1)
    }
}

/// Gövde tipi seçeneklerinden Markdown (2026-10-18) ve SQL (2026-10-19) kalktı.
final class RequestBodyChoicesTests: XCTestCase {
    func testMarkdownAndSQLAreNotOffered() {
        XCTAssertEqual(Beautifier.Kind.requestBodyChoices(current: .json), [.json, .xml, .html, .javascript, .css, .plain])
    }

    func testAnAlreadySavedBodyStillShowsItsType() {
        XCTAssertTrue(Beautifier.Kind.requestBodyChoices(current: .markdown).contains(.markdown))
        XCTAssertTrue(Beautifier.Kind.requestBodyChoices(current: .sql).contains(.sql))
        XCTAssertFalse(Beautifier.Kind.requestBodyChoices(current: .sql).contains(.markdown))
        // Yanıt biçimlemede destek sürüyor.
        XCTAssertEqual(Beautifier.kind(contentType: "text/markdown"), .markdown)
    }
}
