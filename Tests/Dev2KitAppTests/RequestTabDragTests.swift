import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Sekmeyi sürükleyerek sıralama, gerçek fare olaylarıyla (2026-10-31).
///
/// Kullanıcı bildirimleri: (1) bırakınca ~1 sn donukluk (sistem sürükle-bırakı,
/// artık yok); (2) en sola / en sağa yer değiştirilemiyordu: görsel konum grup
/// sınırında sınırlanıyor, karar da sınırlanmış merkezle veriliyordu; uçtaki
/// komşunun ortası tam sınırda olduğu için hiç geçilemiyordu.
///
/// Sekmeler aynı ad ve metotla eşit genişlikte; konumlar hesaplanır, sekmeler
/// kimlikle izlenir.
@MainActor
final class RequestTabDragTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }
    private var window: NSWindow!
    private var ids: [UUID] = []
    /// Sekme genişliği: 2×10 kenar + rozet + 6 + ad + 6 + 14 (kapat yuvası).
    private var width: CGFloat = 0

    override func setUp() async throws {
        harness = AppStateHarness()
        let name = "Istek"
        ids = (0..<3).map { _ in harness.addRequest(named: name).id }
        for id in state.openTabs where !ids.contains(id) { state.closeTab(id) }
        ids.forEach { state.keepTab($0) }
        for (index, id) in ids.enumerated() where state.openTabs[index] != id {
            state.moveTab(id, before: state.openTabs[index])
        }
        XCTAssertEqual(state.openTabs, ids)
        let badge = ("GET" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)]).width
        let text = (name as NSString).size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .callout)]).width
        width = (20 + badge + 6 + text + 6 + 14).rounded()

        let host = NSHostingView(rootView: RequestTabBar().environment(state).frame(width: 900, height: 32))
        window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 900, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        pump(0.5)
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        harness.tearDown()
        harness = nil
    }

    private func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
        window.sendEvent(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )!)
    }

    /// `number` (1…3) numaralı sekmeyi rozetinden tutup `distance` kadar sürükler.
    private func drag(_ number: Int, by distance: CGFloat) {
        let index = CGFloat(state.openTabs.firstIndex(of: ids[number - 1])!)
        let start = NSPoint(x: index * width + 0.25 * width, y: 16)
        mouse(.leftMouseDown, start)
        for step in 1...20 {
            mouse(.leftMouseDragged, NSPoint(x: start.x + distance * CGFloat(step) / 20, y: 16))
            pump(0.01)
        }
        let releasedAt = Date()
        mouse(.leftMouseUp, NSPoint(x: start.x + distance, y: 16))
        pump(0.3)
        XCTAssertLessThan(Date().timeIntervalSince(releasedAt), 1.0, "bırakınca bekleme yok")
    }

    private var order: [Int] { state.openTabs.map { ids.firstIndex(of: $0)! + 1 } }

    func testDraggingToBothEndsAndAgain() {
        drag(3, by: -3 * width)
        XCTAssertEqual(order, [3, 1, 2], "en sola geçer")
        drag(1, by: 3 * width)
        XCTAssertEqual(order, [3, 2, 1], "en sağa geçer")
        drag(1, by: -3 * width)
        XCTAssertEqual(order, [1, 3, 2], "art arda sürüklemeler de çalışır")
        drag(3, by: 0.4 * width)
        XCTAssertEqual(order, [1, 3, 2], "komşunun ortasına varmadan yer değişmez")
        drag(3, by: 1.2 * width)
        XCTAssertEqual(order, [1, 2, 3], "tek komşu")
        XCTAssertNil(state.previewTabID, "sürüklenen sekme kalıcı")
    }

    func testPinnedGroupBoundaryHolds() {
        state.pinTab(ids[0])
        state.pinTab(ids[1])        // [1, 2 | 3]
        pump(0.3)
        drag(2, by: -3 * width)
        XCTAssertEqual(order, [2, 1, 3], "sabitler kendi aralarında en sola")
        drag(3, by: -3 * width)
        XCTAssertEqual(order, [2, 1, 3], "sabit olmayan sabitlerin arasına girmez")
        drag(1, by: 3 * width)
        XCTAssertEqual(order, [2, 1, 3], "sabit, sabit olmayanlara geçmez")
    }
}
