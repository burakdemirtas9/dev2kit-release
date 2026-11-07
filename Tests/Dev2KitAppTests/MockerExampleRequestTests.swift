import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Örnek request body (2026-11-07): kaydedilir, ekranda düzenlenir. Eşleşmeyi
/// etkilemese de değişince "Değişiklikleri Uygula" çıkar (kullanıcı isteği:
/// her tanım değişikliği tutarlı biçimde "değişiklik var").
@MainActor
final class MockerExampleRequestTests: XCTestCase {
    private var root: URL!
    private var state: MockerState?
    private var window: NSWindow?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mocker-example-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        await state?.stop()
        window?.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeState() -> MockerState {
        let base = UInt16.random(in: 20_000...39_000)
        let state = MockerState(root: root, ports: [base, base + 1, base + 2])
        self.state = state
        return state
    }

    func testEditingTheExampleCountsAsAChangeAndIsSaved() async throws {
        let state = makeState()
        state.addEndpoint()
        await state.start()
        XCTAssertTrue(state.isRunning, "\(state.status)")
        state.endpoints[0].requestBody = #"{"amount": 100}"#
        XCTAssertTrue(state.hasUnappliedChanges, "örnek gövde değişikliği de değişiklik")
        XCTAssertEqual(state.modeIndicator, .unapplied(port: try XCTUnwrap(state.port)), "mod seçicide sarı")
        state.applyChanges()
        XCTAssertFalse(state.hasUnappliedChanges)
        // Senaryonun gövdesi (eşleşmeyi etkiler) de.
        state.endpoints[0].scenarios = [MockScenario(requestBody: #"{"amount": 1}"#)]
        state.applyChanges()
        state.endpoints[0].scenarios[0].requestBody = #"{"amount": 2}"#
        XCTAssertTrue(state.hasUnappliedChanges)
        state.flushPendingSave()
        XCTAssertEqual(MockerState(root: root, ports: [1]).endpoints.first?.requestBody, #"{"amount": 100}"#)
    }

    func testEditorShowsTheExampleAboveTheDefaultResponse() throws {
        let state = makeState()
        state.addEndpoint()
        state.endpoints[0].requestBody = "ÖRNEK"
        let host = NSHostingView(rootView: MockerView().environment(state).environment(AppStateHarness().state)
            .frame(width: 1100, height: 800))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func editors(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(editors) }
        let all = editors(host)
        XCTAssertEqual(all.count, 2, "örnek request ve varsayılan response gövdesi")
        let example = try XCTUnwrap(all.first { $0.string == "ÖRNEK" })
        let response = try XCTUnwrap(all.first { $0.string == "{}" })
        XCTAssertGreaterThan(example.convert(example.bounds, to: nil).minY, response.convert(response.bounds, to: nil).minY,
                             "örnek üstte")

        // Editöre yazılan tanıma geçer.
        window.makeFirstResponder(example)
        example.setSelectedRange(NSRange(location: (example.string as NSString).length, length: 0))
        example.insertText("!", replacementRange: example.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(state.endpoints[0].requestBody, "ÖRNEK!")
    }
}
