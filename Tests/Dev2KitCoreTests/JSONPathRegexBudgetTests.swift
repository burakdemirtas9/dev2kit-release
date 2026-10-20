import XCTest
@testable import Dev2KitCore

/// Güvenlik incelemesi F5 (2026-10-20): tek bir regex'in geri izlemesi
/// değerlendirme bütçesinin dışında kalıyordu; `(a+)+$` 33 karakterde
/// bitmiyordu. Artık toplam regex süresi sınırlı, aşınca açık hata.
final class JSONPathRegexBudgetTests: XCTestCase {
    private let adversarial = #"[""# + String(repeating: "a", count: 32) + #"!"]"#

    func testCatastrophicBacktrackingStopsWithALimitError() throws {
        let root = try JSONDocument.parse(adversarial)
        let start = Date()
        XCTAssertThrowsError(try JSONPath.evaluate("$[?match(@, '(a+)+$')]", on: root)) { error in
            XCTAssertTrue(error is JSONPath.LimitError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "süre sınırında durmalı")
    }

    /// Kalıp veriden geliyorsa da (dinamik) aynı sınır geçerli.
    func testDynamicPatternFromDataIsAlsoBounded() throws {
        let root = try JSONDocument.parse(#"{"p": "(a+)+$", "v": [""# + String(repeating: "a", count: 32) + #"!"]}"#)
        let start = Date()
        XCTAssertThrowsError(try JSONPath.evaluate("$.v[?search(@, $.p)]", on: root))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    /// Kontrol: normal regex sonuçları değişmedi.
    func testOrdinaryRegexStillMatches() throws {
        let root = try JSONDocument.parse(#"["apple", "banana", "avocado"]"#)
        XCTAssertEqual(try JSONPath.evaluate("$[?match(@, 'a.*')]", on: root).count, 2)
        XCTAssertEqual(try JSONPath.evaluate("$[?search(@, 'an')]", on: root).count, 1)
    }
}
