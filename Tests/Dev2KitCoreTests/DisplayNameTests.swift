import XCTest
@testable import Dev2KitCore

final class DisplayNameTests: XCTestCase {
    private let limit = DisplayName.environmentPickerLimit

    // MARK: - Kırpma sınırı

    func testShortNameIsUnchanged() {
        XCTAssertEqual(DisplayName.truncated("test", limit: limit), "test")
    }

    func testNameExactlyAtLimitIsNotTruncated() {
        let name = String(repeating: "a", count: limit)
        XCTAssertEqual(DisplayName.truncated(name, limit: limit), name)
    }

    func testNameOneOverLimitIsTruncated() {
        let name = String(repeating: "a", count: limit + 1)
        let result = DisplayName.truncated(name, limit: limit)
        XCTAssertEqual(result, String(repeating: "a", count: limit - 1) + "…")
        XCTAssertEqual(result.count, limit)
    }

    func testResultNeverExceedsLimit() {
        for length in 0...200 {
            let result = DisplayName.truncated(String(repeating: "x", count: length), limit: limit)
            XCTAssertLessThanOrEqual(result.count, limit, "uzunluk \(length) sınırı aştı")
        }
    }

    func testScreenshotCaseIsShortened() {
        // Ekran görüntüsündeki ad: seçici tüm toolbar'ı itiyordu.
        let result = DisplayName.truncated("Yeni Environment123123123123123", limit: limit)
        XCTAssertEqual(result, "Yeni Environment1231231…")
        XCTAssertEqual(result.count, limit)
    }

    // MARK: - Boşluk ve boş ad

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(DisplayName.truncated("  test \n", limit: limit), "test")
    }

    func testWhitespaceOnlyNameBecomesEmpty() {
        XCTAssertEqual(DisplayName.truncated("   ", limit: limit), "")
        XCTAssertEqual(DisplayName.truncated("", limit: limit), "")
    }

    func testTrailingSpaceAtCutIsRemovedBeforeEllipsis() {
        // Kırpma noktası boşluğa denk gelirse "… " gibi bir sonuç çıkmamalı.
        let name = "abcdefghijklmnopqrstuv wxyz1234"
        let result = DisplayName.truncated(name, limit: limit)
        XCTAssertEqual(result, "abcdefghijklmnopqrstuv…")
        XCTAssertFalse(result.contains(" …"))
    }

    // MARK: - Türkçe ve emoji

    func testTurkishCharactersCountAsOne() {
        // 24 Türkçe harf: sınırda, kırpılmamalı.
        let name = String(repeating: "ğ", count: limit)
        XCTAssertEqual(DisplayName.truncated(name, limit: limit), name)
    }

    func testEmojiIsNotSplit() {
        let name = String(repeating: "👨‍👩‍👧‍👦", count: limit + 5)
        let result = DisplayName.truncated(name, limit: limit)
        XCTAssertEqual(result, String(repeating: "👨‍👩‍👧‍👦", count: limit - 1) + "…")
        XCTAssertEqual(result.count, limit)
    }

    // MARK: - Sınır değerleri

    func testZeroAndNegativeLimitGiveEmptyString() {
        XCTAssertEqual(DisplayName.truncated("test", limit: 0), "")
        XCTAssertEqual(DisplayName.truncated("test", limit: -5), "")
    }

    func testLimitOfOneGivesOnlyEllipsis() {
        XCTAssertEqual(DisplayName.truncated("test", limit: 1), "…")
    }
}
