import XCTest
@testable import Dev2KitApp

final class EditorZoomTests: XCTestCase {
    func testZoomStaysInRange() {
        XCTAssertEqual(EditorZoom.zoomed(13, by: 1), 14)
        XCTAssertEqual(EditorZoom.zoomed(EditorZoom.range.upperBound, by: 1), EditorZoom.range.upperBound)
        XCTAssertEqual(EditorZoom.zoomed(EditorZoom.range.lowerBound, by: -1), EditorZoom.range.lowerBound)
    }

    func testGutterScalesWithEditor() {
        XCTAssertEqual(EditorZoom.gutterSize(EditorZoom.standard), 10, "varsayılanda eski 10 pt")
        XCTAssertGreaterThan(EditorZoom.gutterSize(20), 10)
    }
}
