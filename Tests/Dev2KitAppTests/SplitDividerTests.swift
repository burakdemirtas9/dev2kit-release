import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı isteği (2026-10-21): ayraçlar fark edilir, 8–12 pt yakalama
/// alanı, doğru resize imleci; sürüklerken imleç korunur, bitince alana göre.
@MainActor
final class SplitDividerTests: XCTestCase {
    private var harness: AppStateHarness!
    private var window: NSWindow!

    override func setUp() {
        harness = AppStateHarness()
        UserDefaults.standard.removeObject(forKey: "responseHeight")
    }

    override func tearDown() {
        window?.orderOut(nil)
        harness.tearDown()
        UserDefaults.standard.removeObject(forKey: "responseHeight")
    }

    private func settle(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func host(_ view: some View, width: CGFloat = 1140, height: CGFloat = 600) -> NSView {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: height),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        settle(0.8)
        return host
    }

    private func handles(_ view: NSView) -> [SplitHandleView] {
        ((view as? SplitHandleView).map { [$0] } ?? []) + view.subviews.flatMap(handles)
    }

    private func textOwners(_ view: NSView) -> [NSView] {
        ((view is NSTextView || view is NSTextField) ? [view] : []) + view.subviews.flatMap(textOwners)
    }

    private func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    private func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Ayracı tutup (dx, dy) kadar sürükler (pencere koordinatı; dy aşağı pozitif).
    /// Sürükleme ortasındaki imleç ve cursor rect durumunu döner.
    @discardableResult
    private func drag(_ handle: SplitHandleView, dx: CGFloat = 0, dy: CGFloat = 0, steps: Int = 4) -> (cursor: NSCursor?, rectsEnabled: Bool) {
        let rect = frame(handle)
        let start = NSPoint(x: rect.midX, y: rect.midY)
        handle.mouseDown(with: event(.leftMouseDown, start))
        var during: (NSCursor?, Bool) = (nil, true)
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            handle.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: start.x + dx * fraction, y: start.y - dy * fraction)))
            if step == steps { during = (NSCursor.current, window.areCursorRectsEnabled) }
        }
        handle.mouseUp(with: event(.leftMouseUp, NSPoint(x: start.x + dx, y: start.y - dy)))
        settle()
        return during
    }

    private func apiClient() -> (root: NSView, sidebar: SplitHandleView, response: SplitHandleView) {
        // Kenar çubuğu içeriğinden geniş olamıyor: uzun ad, büyüme payı için.
        harness.addRequest(named: String(repeating: "Uzun istek adı ", count: 4), url: "https://api.example.com/users")
        let root = host(APIClientLayout().environment(harness.state))
        let all = handles(root)
        let sidebar = all.first { $0.axis == .horizontal }!
        let response = all.first { $0.axis == .vertical }!
        return (root, sidebar, response)
    }

    func testGripAreasAreTenPointsAlongTheWholeLengthAndClearOfEditors() {
        let (root, sidebar, response) = apiClient()
        XCTAssertEqual(handles(root).count, 2)
        XCTAssertEqual(frame(sidebar).width, SplitDivider.thickness)
        XCTAssertEqual(frame(sidebar).height, 600, "kenar çubuğu ayracı tüm yükseklikte")
        XCTAssertEqual(frame(response).height, SplitDivider.thickness)
        XCTAssertEqual(frame(response).width, 1140 - frame(sidebar).maxX, accuracy: 0.5, "yanıt ayracı detay genişliğinde")
        XCTAssertTrue(sidebar.cursor === NSCursor.resizeLeftRight)
        XCTAssertTrue(response.cursor === NSCursor.resizeUpDown)
        for handle in [sidebar, response] {
            let rect = frame(handle)
            XCTAssertTrue(root.hitTest(NSPoint(x: rect.midX, y: rect.midY)) === handle, "yakalama alanı fareyi alır")
            for text in textOwners(root) {
                XCTAssertFalse(rect.intersects(frame(text)), "ayraç metin alanına binmez: \(frame(text))")
            }
        }
    }

    func testSidebarDragsBothWaysWithinLimitsAndPersists() {
        let (_, sidebar, _) = apiClient()
        let start = frame(sidebar).minX
        drag(sidebar, dx: 80)
        XCTAssertEqual(frame(sidebar).minX, start + 80, accuracy: 0.5, "sağa")
        drag(sidebar, dx: -40)
        XCTAssertEqual(frame(sidebar).minX, start + 40, accuracy: 0.5, "sola")
        XCTAssertEqual(UserDefaults.standard.double(forKey: "sidebarWidth"), Double(start + 40), accuracy: 0.5, "bırakılan genişlik saklanır")

        drag(sidebar, dx: -5_000, steps: 1)
        XCTAssertEqual(frame(sidebar).minX, 220, accuracy: 0.5, "hızlı sürükleme asgaride durur")
        drag(sidebar, dx: 5_000, steps: 1)
        XCTAssertLessThanOrEqual(frame(sidebar).maxX, 1140 - 480 + 0.5, "detaya en az 480 pt kalır")
    }

    func testResponseDragsBothWaysWithinLimits() {
        let (_, _, response) = apiClient()
        let start = frame(response).minY
        drag(response, dy: 60)
        XCTAssertEqual(frame(response).minY, start - 60, accuracy: 0.5, "aşağı: yanıt küçülür")
        drag(response, dy: -30)
        XCTAssertEqual(frame(response).minY, start - 30, accuracy: 0.5, "yukarı")

        drag(response, dy: 5_000, steps: 1)
        XCTAssertEqual(frame(response).minY, 160, accuracy: 0.5, "yanıt asgarisi 160")
        drag(response, dy: -5_000, steps: 1)
        XCTAssertGreaterThanOrEqual(600 - frame(response).maxY, 220 - 0.5, "üst panel asgarisi 220")
    }

    func testResizeCursorIsHeldDuringDragAndCursorRectsComeBack() {
        let (_, sidebar, response) = apiClient()
        let during = drag(sidebar, dx: 300, steps: 6)
        XCTAssertTrue(during.cursor === NSCursor.resizeLeftRight, "alandan çıksa da ↔")
        XCTAssertFalse(during.rectsEnabled, "komşu cursor rect'leri sürüklerken devre dışı")
        XCTAssertTrue(window.areCursorRectsEnabled, "bitince geri açılır")
        XCTAssertFalse(sidebar.isDragging)

        let vertical = drag(response, dy: 40)
        XCTAssertTrue(vertical.cursor === NSCursor.resizeUpDown)
        XCTAssertTrue(window.areCursorRectsEnabled)
    }

    /// Bırakınca imleç bırakılan yere göre: ayracın üstündeyse resize, değilse
    /// alttaki görünümünki (SwiftUI düğmeleri/boş alan: ok).
    func testCursorAfterDropMatchesTheLocation() {
        let (_, sidebar, _) = apiClient()
        drag(sidebar, dx: 0, dy: 0)
        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight, "ayraçta bırakıldı")
        drag(sidebar, dx: 40, dy: 200)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "ayraçtan uzakta bırakıldı: takılı kalmaz")
    }

    /// Editörün üstünde bırakınca I-beam (sürükleme bitti, alan metin alanı).
    func testDropOverEditorGivesIBeam() throws {
        let state = WorkbenchState()
        state.select(toolID: "json")
        defer { UserDefaults.standard.removeObject(forKey: "workbenchTool") }
        let root = host(WorkbenchView().environment(state))
        let handle = try XCTUnwrap(handles(root).first)
        func editors(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(editors) }
        let output = try XCTUnwrap(editors(root).max { frame($0).minX < frame($1).minX })
        let target = frame(output)
        let rect = frame(handle)
        drag(handle, dx: target.midX - rect.midX, dy: rect.midY - target.midY, steps: 1)
        // Ayraç kaydı ama fare hâlâ çıktı editörünün üstünde kalacak kadar uzakta.
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam)
    }

    /// Editör odaktayken sürükleme odağı almaz, metin seçmez.
    func testDraggingKeepsEditorFocusAndSelection() throws {
        let (root, sidebar, response) = apiClient()
        func address(_ view: NSView) -> AddressTextView? { (view as? AddressTextView) ?? view.subviews.lazy.compactMap(address).first }
        let editor = try XCTUnwrap(address(root))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        drag(sidebar, dx: 30)
        drag(response, dy: 30)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertFalse(sidebar.acceptsFirstResponder)
    }

    func testWorkbenchPanesResizeBothWaysAndKeepMinimums() {
        let state = WorkbenchState()
        state.select(toolID: "json")
        defer { UserDefaults.standard.removeObject(forKey: "workbenchTool") }
        let root = host(WorkbenchView().environment(state))
        let all = handles(root)
        XCTAssertEqual(all.count, 1, "yalnızca girdi/çıktı ayracı (araç listesi sabit genişlikte)")
        let handle = all[0]
        XCTAssertTrue(handle.cursor === NSCursor.resizeLeftRight)
        XCTAssertEqual(frame(handle).width, SplitDivider.thickness)
        let start = frame(handle).minX
        drag(handle, dx: 70)
        XCTAssertEqual(frame(handle).minX, start + 70, accuracy: 0.5)
        drag(handle, dx: -120)
        XCTAssertEqual(frame(handle).minX, start - 50, accuracy: 0.5)
        drag(handle, dx: -5_000, steps: 1)
        XCTAssertEqual(frame(handle).minX - 220, 260, accuracy: 1, "girdi asgarisi 260")
        drag(handle, dx: 5_000, steps: 1)
        XCTAssertEqual(1140 - frame(handle).maxX, 260, accuracy: 1, "çıktı asgarisi 260")
    }
}
