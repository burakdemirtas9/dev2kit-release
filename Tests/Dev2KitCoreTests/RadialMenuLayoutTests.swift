import XCTest
@testable import Dev2KitCore

final class RadialMenuLayoutTests: XCTestCase {
    private let layout = RadialMenuLayout(count: 6, radius: 60)

    private func assertPoint(_ point: CGPoint, _ x: Double, _ y: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(point.x, x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(point.y, y, accuracy: 0.001, file: file, line: line)
    }

    /// Tetikleyici çemberin tepesinde; diğerleri saat yönünde:
    /// üst → sağ üst → sağ alt → alt → sol alt → sol üst.
    func testItemsSitClockwiseFromTheTop() {
        assertPoint(layout.finalPosition(of: 0), 0, 0)
        let p = (0..<6).map(layout.finalPosition(of:))
        XCTAssertGreaterThan(p[1].x, 0); XCTAssertLessThan(p[1].y, 60)    // sağ üst
        XCTAssertGreaterThan(p[2].x, 0); XCTAssertGreaterThan(p[2].y, 60) // sağ alt
        assertPoint(p[3], 0, 120)                                           // alt
        XCTAssertLessThan(p[4].x, 0); XCTAssertGreaterThan(p[4].y, 60)    // sol alt
        XCTAssertLessThan(p[5].x, 0); XCTAssertLessThan(p[5].y, 60)       // sol üst
    }

    func testItemsAreEvenlySpacedOnTheCircle() {
        let distances = (0..<6).map { index -> Double in
            let a = layout.finalPosition(of: index), b = layout.finalPosition(of: (index + 1) % 6)
            return hypot(a.x - b.x, a.y - b.y)
        }
        for distance in distances { XCTAssertEqual(distance, 60, accuracy: 0.001) } // altıgen: kenar = yarıçap
        for index in 0..<6 {
            let p = layout.finalPosition(of: index)
            XCTAssertEqual(hypot(p.x - layout.center.x, p.y - layout.center.y), 60, accuracy: 0.001)
        }
    }

    /// Her öğe tetikleyicinin yerinden doğar ve kendi yerinde biter.
    func testPathStartsAtTheTriggerAndEndsAtTheSlot() {
        for index in 1..<6 {
            assertPoint(layout.position(of: index, progress: 0), 0, 0)
            let end = layout.finalPosition(of: index)
            assertPoint(layout.position(of: index, progress: 1), end.x, end.y)
        }
    }

    /// Kavis saat yönünü destekler: alttaki öğe yolun ortasında sağa taşar
    /// (düz kiriş x = 0 olurdu).
    func testPathBulgesClockwise() {
        let middle = layout.position(of: 3, progress: 0.5)
        XCTAssertGreaterThan(middle.x, 5)
        let straight = RadialMenuLayout(count: 6, radius: 60, curvature: 0)
        XCTAssertEqual(straight.position(of: 3, progress: 0.5).x, 0, accuracy: 0.001)
    }

    func testScaleGrowsFromADotAndEarlierItemsAreLarger() {
        XCTAssertEqual(layout.scale(progress: 0), 0.12, accuracy: 0.001)
        XCTAssertEqual(layout.scale(progress: 1), 1, accuracy: 0.001)
        XCTAssertGreaterThan(layout.scale(progress: 0.8), layout.scale(progress: 0.3))
        XCTAssertEqual(layout.opacity(progress: 0), 0)
        XCTAssertEqual(layout.opacity(progress: 0.5), 1)
    }

    func testClosingIsTheReverseOfOpening() {
        XCTAssertEqual(layout.openingOrder, [1, 2, 3, 4, 5])
        XCTAssertEqual(layout.closingOrder, [5, 4, 3, 2, 1])
        XCTAssertFalse(layout.openingOrder.contains(0), "tetikleyici yerinde kalır")
    }

    func testBoundsHangBelowTheTrigger() {
        let bounds = layout.bounds(itemDiameter: 36, margin: 4)
        XCTAssertEqual(bounds.minY, -22, accuracy: 0.001)
        XCTAssertEqual(bounds.maxY, 120 + 22, accuracy: 0.001)
        XCTAssertEqual(bounds.midX, 0, accuracy: 0.001)
    }

    func testMinimumRadiusKeepsItemsApart() {
        let radius = RadialMenuLayout.minimumRadius(count: 6, itemDiameter: 36, gap: 12)
        XCTAssertEqual(RadialMenuLayout(count: 6, radius: radius).gap(itemDiameter: 36), 12, accuracy: 0.001)
        XCTAssertLessThan(RadialMenuLayout(count: 6, radius: 30).gap(itemDiameter: 36), 0)
    }

    func testFewerItemsStillStartAtTheTop() {
        let three = RadialMenuLayout(count: 3, radius: 50)
        assertPoint(three.finalPosition(of: 0), 0, 0)
        XCTAssertGreaterThan(three.finalPosition(of: 1).x, 0, "ikinci öğe sağda (saat yönü)")
        XCTAssertEqual(three.openingOrder, [1, 2])
    }
}
