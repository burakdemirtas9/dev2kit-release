import XCTest
@testable import Dev2KitCore

final class TextSearchTests: XCTestCase {

    // MARK: - Düz metin arama

    func testFindsEveryOccurrence() {
        let result = TextSearch.find("ad", in: "ad soyad ad")
        XCTAssertEqual(result.ranges.map(\.location), [0, 6, 9])
        XCTAssertFalse(result.isTruncated)
        XCTAssertFalse(result.isInvalidPattern)
    }

    func testIsCaseInsensitiveByDefault() {
        let result = TextSearch.find("json", in: "JSON json Json")
        XCTAssertEqual(result.count, 3)
    }

    func testCaseSensitiveOptionNarrowsResults() {
        let result = TextSearch.find(
            "json",
            in: "JSON json Json",
            options: .init(caseSensitive: true)
        )
        XCTAssertEqual(result.ranges.map(\.location), [5])
    }

    func testEmptyQueryFindsNothingAndIsNotAnError() {
        let result = TextSearch.find("", in: "bir metin")
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(result.isInvalidPattern)
    }

    func testEmptyTextFindsNothing() {
        XCTAssertTrue(TextSearch.find("ad", in: "").isEmpty)
    }

    func testOverlappingOccurrencesAreNotDoubleCounted() {
        // "aa" içinde "aaa" iki değil bir kez bulunur: eşleşmeler çakışmaz,
        // yoksa aynı karakter iki kez boyanır ve gezinme yerinde sayar.
        let result = TextSearch.find("aa", in: "aaa")
        XCTAssertEqual(result.ranges.map(\.location), [0])
    }

    func testMatchesCarryCorrectLength() {
        let result = TextSearch.find("soyad", in: "ad soyad")
        XCTAssertEqual(result.ranges.first, NSRange(location: 3, length: 5))
    }

    func testStopsAtMatchLimitAndReportsTruncation() {
        let text = String(repeating: "x", count: TextSearch.matchLimit + 50)
        let result = TextSearch.find("x", in: text)
        XCTAssertEqual(result.count, TextSearch.matchLimit)
        XCTAssertTrue(result.isTruncated)
    }

    // MARK: - Regex arama

    func testRegexMatches() {
        let result = TextSearch.find(
            #""[a-z]+":"#,
            in: #"{"ad": "Ali", "il": "Istanbul"}"#,
            options: .init(isRegex: true)
        )
        XCTAssertEqual(result.count, 2)
    }

    func testInvalidPatternIsReportedNotCrashed() {
        // Kullanıcı kalıbı yazarken metin yarım kalır: "(" tek başına geçersiz.
        let result = TextSearch.find("(", in: "metin", options: .init(isRegex: true))
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(result.isInvalidPattern)
    }

    func testZeroLengthRegexMatchesAreDropped() {
        // `a*` her konumda boş eşleşme üretir; boyanacak yerleri yok.
        let result = TextSearch.find("a*", in: "bab", options: .init(isRegex: true))
        XCTAssertEqual(result.ranges.map(\.location), [1])
        XCTAssertEqual(result.ranges.first?.length, 1)
    }

    func testRegexRespectsCaseOption() {
        let insensitive = TextSearch.find("AD", in: "ad", options: .init(isRegex: true))
        XCTAssertEqual(insensitive.count, 1)
        let sensitive = TextSearch.find(
            "AD",
            in: "ad",
            options: .init(caseSensitive: true, isRegex: true)
        )
        XCTAssertTrue(sensitive.isEmpty)
    }

    func testRegexAlsoStopsAtMatchLimit() {
        let text = String(repeating: "x", count: TextSearch.matchLimit + 50)
        let result = TextSearch.find("x", in: text, options: .init(isRegex: true))
        XCTAssertEqual(result.count, TextSearch.matchLimit)
        XCTAssertTrue(result.isTruncated)
    }

    // MARK: - Gezinme

    func testStepFromNothingStartsAtEitherEnd() {
        XCTAssertEqual(TextSearch.step(from: nil, count: 3, forward: true), 0)
        XCTAssertEqual(TextSearch.step(from: nil, count: 3, forward: false), 2)
    }

    func testStepMovesOneAtATime() {
        XCTAssertEqual(TextSearch.step(from: 0, count: 3, forward: true), 1)
        XCTAssertEqual(TextSearch.step(from: 2, count: 3, forward: false), 1)
    }

    func testStepWrapsAtBothEnds() {
        XCTAssertEqual(TextSearch.step(from: 2, count: 3, forward: true), 0)
        XCTAssertEqual(TextSearch.step(from: 0, count: 3, forward: false), 2)
    }

    func testStepWithoutMatchesReturnsNil() {
        XCTAssertNil(TextSearch.step(from: nil, count: 0, forward: true))
        XCTAssertNil(TextSearch.step(from: 0, count: 0, forward: false))
    }

    func testFirstIndexContinuesFromCaret() {
        let ranges = [
            NSRange(location: 5, length: 2),
            NSRange(location: 40, length: 2),
            NSRange(location: 90, length: 2),
        ]
        XCTAssertEqual(TextSearch.firstIndex(atOrAfter: 0, in: ranges), 0)
        XCTAssertEqual(TextSearch.firstIndex(atOrAfter: 6, in: ranges), 1)
        XCTAssertEqual(TextSearch.firstIndex(atOrAfter: 40, in: ranges), 1)
    }

    func testFirstIndexWrapsWhenNothingIsAhead() {
        let ranges = [NSRange(location: 5, length: 2)]
        XCTAssertEqual(TextSearch.firstIndex(atOrAfter: 900, in: ranges), 0)
    }

    func testFirstIndexWithoutMatchesReturnsNil() {
        XCTAssertNil(TextSearch.firstIndex(atOrAfter: 0, in: []))
    }
}
