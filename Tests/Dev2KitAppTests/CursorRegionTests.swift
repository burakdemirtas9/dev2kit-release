import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı bildirimi (2026-10-21): Gönder gibi düğmelerde I-beam görünüyordu.
/// Sebep `NSCursor.push()/pop()`: `pop()` itme anındaki imleci (arama
/// alanından gelen I-beam) geri yüklüyor, SwiftUI düğmeleri de imleci
/// düzeltmiyordu. İmleçler artık bileşenin sınırına bağlı cursor rect.
@MainActor
final class CursorRegionTests: XCTestCase {
    private final class RecordingRegionView: CursorRegionView {
        var registered: [(NSRect, NSCursor)] = []
        override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) {
            registered.append((rect, object))
            super.addCursorRect(rect, cursor: object)
        }
    }

    func testRegistersOnlyItsOwnBoundsAndLetsClicksThrough() {
        let view = RecordingRegionView(cursor: .resizeUpDown)
        view.frame = NSRect(x: 10, y: 20, width: 300, height: 9)
        view.resetCursorRects()
        XCTAssertEqual(view.registered.count, 1)
        XCTAssertEqual(view.registered.first?.0, view.bounds)
        XCTAssertTrue(view.registered.first?.1 === NSCursor.resizeUpDown)
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 24)), "tıklama altındaki görünüme gider")
        XCTAssertFalse(view.acceptsFirstResponder, "klavye odağını almaz")
    }
}
