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

    private func regions(_ view: NSView) -> [CursorRegionView] {
        ((view as? CursorRegionView).map { [$0] } ?? []) + view.subviews.flatMap(regions)
    }

    private func textViews(_ view: NSView) -> [NSView] {
        ((view is NSTextView || view is NSTextField) ? [view] : []) + view.subviews.flatMap(textViews)
    }

    /// Ayraçların imleci yalnızca tutma alanında; hiçbir metin alanına binmez
    /// (adres alanı ve Gönder satırı dahil).
    func testDividerCursorsStayOnTheirGripAreas() throws {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        harness.addRequest(named: "R", url: "https://api.example.com/users")
        let host = NSHostingView(rootView: APIClientLayout().environment(harness.state).frame(width: 1140, height: 560))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1140, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let found = regions(host)
        let columns = found.filter { $0.cursor === NSCursor.resizeLeftRight }
        let rows = found.filter { $0.cursor === NSCursor.resizeUpDown }
        XCTAssertEqual(columns.count, 1, "kenar çubuğu ayracı")
        XCTAssertEqual(rows.count, 1, "istek/yanıt ayracı")
        XCTAssertEqual(columns.first?.frame.width, 9)
        XCTAssertEqual(rows.first?.frame.height, 9)

        // Tıklama/sürükleme SwiftUI'ya ulaşır (ayraç hareketi bozulmaz).
        for region in columns + rows {
            let rect = region.convert(region.bounds, to: nil)
            let hit = host.hitTest(host.superview?.convert(NSPoint(x: rect.midX, y: rect.midY), from: nil) ?? .zero)
            XCTAssertTrue(hit === host, "ayraçta tıklama SwiftUI hareketine gitmeli")
        }

        let texts = textViews(host).map { $0.convert($0.bounds, to: nil) }
        XCTAssertFalse(texts.isEmpty)
        for region in columns + rows {
            let rect = region.convert(region.bounds, to: nil)
            for text in texts {
                XCTAssertFalse(rect.intersects(text), "\(rect) metin alanına biniyor: \(text)")
            }
        }
    }
}
