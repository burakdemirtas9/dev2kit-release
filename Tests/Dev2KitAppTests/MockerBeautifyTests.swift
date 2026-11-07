import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Mocker gövde alanlarında Beautify (kullanıcı isteği, 2026-11-07): API
/// Client gövdesiyle aynı kural (`Beautifier`) ve metinler.
@MainActor
final class MockerBeautifyTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow?

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mocker-beautify-\(UUID().uuidString)")
    }

    override func tearDown() {
        window?.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
    }

    private func pump(_ seconds: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func editors(_ view: NSView) -> [NSTextView] {
        ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(editors)
    }

    /// Beautify her gövde editörünün sağ üstünde (başlık satırının sonunda).
    /// SwiftUI düğmesi `NSButton` değil; gerçek fare tıklamasıyla basılır.
    private func clickBeautify(above editor: NSTextView) {
        guard let window = editor.window, let scroll = editor.enclosingScrollView else { return }
        let frame = scroll.convert(scroll.bounds, to: nil)
        let point = NSPoint(x: frame.maxX - 30, y: frame.maxY + 14)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        pump(0.2)
    }

    private func host(_ state: MockerState) -> NSView {
        let host = NSHostingView(rootView: MockerView().environment(state).environment(AppStateHarness().state)
            .frame(width: 1100, height: 1500))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1100, height: 1500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
        pump()
        return host
    }

    func testEveryBodyFieldHasBeautifyAndItFormats() throws {
        let state = MockerState(root: root, ports: [1])
        state.addEndpoint()
        state.endpoints[0].requestBody = #"{"amount":100,"currency":"TRY"}"#
        state.endpoints[0].response.body = #"{"status":"OK","items":[1,2]}"#
        state.endpoints[0].scenarios = [MockScenario(name: "s", response: MockResponse(body: #"{"x":1}"#), requestBody: #"{"amount":5}"#)]
        let root = host(state)
        let all = editors(root)
        XCTAssertEqual(all.count, 4, "örnek request, varsayılan response, senaryo request ve response")
        all.forEach(clickBeautify(above:))
        XCTAssertEqual(state.endpoints[0].requestBody, "{\n  \"amount\": 100,\n  \"currency\": \"TRY\"\n}")
        XCTAssertTrue(state.endpoints[0].response.body.contains("\n  \"items\": ["), state.endpoints[0].response.body)
        XCTAssertEqual(state.endpoints[0].scenarios[0].requestBody, "{\n  \"amount\": 5\n}")
        XCTAssertEqual(state.endpoints[0].scenarios[0].response.body, "{\n  \"x\": 1\n}")
    }

    func testBrokenJSONKeepsTheText() throws {
        let state = MockerState(root: root, ports: [1])
        state.addEndpoint()
        state.endpoints[0].response.body = #"{"a": 1,"#
        let root = host(state)
        let editor = try XCTUnwrap(editors(root).first { $0.string == #"{"a": 1,"# })
        clickBeautify(above: editor)
        XCTAssertEqual(state.endpoints[0].response.body, #"{"a": 1,"#, "bozuk metin değişmez")
    }

    func testPlainTextIsLeftAlone() throws {
        let state = MockerState(root: root, ports: [1])
        state.addEndpoint()
        state.endpoints[0].response.headers = []
        state.endpoints[0].response.body = "düz  metin"
        let root = host(state)
        let editor = try XCTUnwrap(editors(root).first { $0.string == "düz  metin" })
        clickBeautify(above: editor)
        XCTAssertEqual(state.endpoints[0].response.body, "düz  metin", "düz metin biçimlendirilmez")
    }
}
