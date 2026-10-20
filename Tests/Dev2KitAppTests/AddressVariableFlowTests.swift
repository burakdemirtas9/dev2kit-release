import XCTest
import SwiftUI
import AppKit
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Adres alanındaki tanımsız değişken: baloncuktaki "Environment değişkeni
/// ekle" ile değer verilince alan hemen yeniden boyanır (eskiden renk
/// AppKit tarafında hesaplandığı için kırmızı kalıyordu).
@MainActor
final class AddressVariableFlowTests: XCTestCase {
    private struct Bar: View {
        @State var url: String
        @State var method = HTTPMethod.get
        var body: some View {
            TemplateTextField(placeholder: "", text: $url, limit: .url, onSubmit: {},
                              capsuleLeading: AnyView(MethodPicker(selection: $method, bordered: false).frame(width: 92)))
                .frame(width: 600)
        }
    }

    private func find(_ view: NSView) -> AddressTextView? {
        (view as? AddressTextView) ?? view.subviews.lazy.compactMap(find).first
    }

    private func color(of needle: String, in textView: NSTextView) -> NSColor? {
        let range = (textView.string as NSString).range(of: needle)
        return textView.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    func testSavingTheValueRecolorsTheAddress() throws {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let env = EnvironmentModel(name: "TestEnv")
        harness.state.workspace.environments = [env]
        harness.state.workspace.activeEnvironmentID = env.id

        let host = NSHostingView(rootView: Bar(url: "https://a.test/{{base}}/x").environment(harness.state))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 600, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let textView = try XCTUnwrap(find(host))
        XCTAssertEqual(color(of: "{{base}}", in: textView), Theme.undefinedVariableNS)

        // Baloncuktaki düğmenin yaptığı: pencereyi açma isteği, sonra kaydetme.
        harness.state.defineVariable("base")
        let request = try XCTUnwrap(harness.state.takeVariableDefinitionRequest())
        XCTAssertEqual(request.key, "base")
        XCTAssertEqual(request.target, .environment(env.id))
        try harness.state.saveVariable(key: request.key, value: "v1", environmentID: env.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(color(of: "{{base}}", in: textView), Theme.variableNS)
        XCTAssertEqual(textView.string, "https://a.test/{{base}}/x")
    }

    /// Boş durumdan yeni istek: adres alanı açılınca odakta.
    func testPendingAddressFocusFocusesTheEditor() throws {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        harness.state.addressFocusPending = true
        let host = NSHostingView(rootView: Bar(url: "").environment(harness.state))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 600, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let textView = try XCTUnwrap(find(host))
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertFalse(harness.state.addressFocusPending)
    }
}
