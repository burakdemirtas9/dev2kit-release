import XCTest
@testable import Dev2KitCore

/// Katlı bölgede "… 30 items" (kullanıcı isteği, 2026-10-19).
final class FoldSummaryTests: XCTestCase {
    private func summaries(_ json: String) -> [String] {
        JSONFolding.regions(in: json).map { $0.summary(in: json as NSString) }
    }

    func testCountsDirectChildrenOnly() {
        let json = """
        {
          "a": 1,
          "b": { "x": [1, 2], "y": "}, ]" },
          "c": [
            1,
            2,
            3
          ]
        }
        """
        XCTAssertEqual(summaries(json), ["… 3 keys", "… 3 items"])
    }

    func testSingularAndEmpty() {
        XCTAssertEqual(summaries("{\n  \"a\": 1\n}"), ["… 1 key"])
        XCTAssertEqual(summaries("[\n  \"tek\"\n]"), ["… 1 item"])
        XCTAssertEqual(summaries("[\n\n]"), ["… 0 items"], "boş ama çok satırlı blok")
    }

    func testMarkupShowsHiddenLines() {
        let xml = "<a>\n  <b>1</b>\n  <c>2</c>\n</a>"
        XCTAssertEqual(MarkupFolding.regions(in: xml).map { $0.summary(in: xml as NSString) }, ["… 2 lines"])
    }
}
