import XCTest
@testable import Dev2KitCore

final class SplitSizingTests: XCTestCase {
    func testDragStaysWithinBounds() {
        XCTAssertEqual(SplitSizing.resized(start: 300, delta: 40, lower: 220, upper: 500), 340)
        XCTAssertEqual(SplitSizing.resized(start: 300, delta: -200, lower: 220, upper: 500), 220, "asgari")
        XCTAssertEqual(SplitSizing.resized(start: 300, delta: 900, lower: 220, upper: 500), 500, "azami")
    }

    /// Hızlı sürükleme tek olayda büyük bir sıçrama getirir: yine sınırda kalır.
    func testFastDragJumpsAreClamped() {
        XCTAssertEqual(SplitSizing.resized(start: 220, delta: -10_000, lower: 160, upper: 400), 160)
        XCTAssertEqual(SplitSizing.resized(start: 220, delta: 10_000, lower: 160, upper: 400), 400)
    }

    /// Dar pencere: üst sınır alt sınırın altına düşse de panel asgarisinde kalır.
    func testNarrowWindowKeepsTheMinimum() {
        XCTAssertEqual(SplitSizing.resized(start: 300, delta: 50, lower: 220, upper: 100), 220)
        XCTAssertEqual(SplitSizing.firstPane(fraction: 0.5, available: 400, minFirst: 260, minSecond: 260), 260)
    }

    func testFirstPaneRespectsBothMinimums() {
        XCTAssertEqual(SplitSizing.firstPane(fraction: 0.5, available: 1000, minFirst: 260, minSecond: 260), 500)
        XCTAssertEqual(SplitSizing.firstPane(fraction: 0.05, available: 1000, minFirst: 260, minSecond: 260), 260)
        XCTAssertEqual(SplitSizing.firstPane(fraction: 0.95, available: 1000, minFirst: 260, minSecond: 260), 740)
        XCTAssertEqual(SplitSizing.firstPane(fraction: .nan, available: 1000, minFirst: 260, minSecond: 260), 500)
    }
}
