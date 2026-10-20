import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı isteği (2026-10-19): Params'a yazılan, yazma bitince adres
/// çubuğuna sırayla eklensin; adrese yazılan tabloya düşsün.
@MainActor
final class QueryParamSyncUITests: XCTestCase {
    final class Model: ObservableObject { @Published var request = RequestModel(name: "r", method: .get, url: "https://api.example.com/v1/users") }

    private struct Host: View {
        @ObservedObject var model: Model
        var body: some View { RequestDetailView(request: $model.request).frame(width: 900, height: 600) }
    }

    private func textFields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
    }

    private func addressEditor(_ view: NSView) -> AddressTextView? {
        (view as? AddressTextView) ?? view.subviews.lazy.compactMap(addressEditor).first
    }

    private func type(_ text: String, into field: NSTextField, window: NSWindow) throws {
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView ?? window.firstResponder as? NSTextView)
        editor.insertText(text, replacementRange: editor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    func testBothDirections() throws {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        harness.state.editorTab = .params
        let model = Model()
        let host = NSHostingView(rootView: Host(model: model).environment(harness.state))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        // Tablodan adrese.
        try type("name", into: try XCTUnwrap(textFields(host).first { $0.placeholderString == "param" }), window: window)
        // Değer hücresi: "name" yazılan hücreyle aynı satırda, sağındaki alan.
        func windowFrame(_ field: NSTextField) -> NSRect { field.convert(field.bounds, to: nil) }
        let keyCell = try XCTUnwrap(textFields(host).first { $0.stringValue == "name" })
        let rowValue = try XCTUnwrap(textFields(host).first {
            abs(windowFrame($0).midY - windowFrame(keyCell).midY) < 4 && windowFrame($0).minX > windowFrame(keyCell).maxX
        })
        try type("xyz", into: rowValue, window: window)
        XCTAssertEqual(model.request.url, "https://api.example.com/v1/users", "yazarken adres değişmez")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(model.request.url, "https://api.example.com/v1/users?name=xyz", "yazma bitince adrese eklenir")

        // Adresten tabloya.
        // Adres alanı bir metin görünümü (`URLEditor`, 2026-10-20).
        let editor = try XCTUnwrap(addressEditor(host))
        XCTAssertTrue(editor.string.hasPrefix("https://api.example.com"))
        window.makeFirstResponder(editor)
        editor.insertText("&page=2", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        XCTAssertEqual(model.request.queryParams.map(\.key), ["name", "page"])
        XCTAssertEqual(model.request.queryParams.map(\.value), ["xyz", "2"])
    }

    func testSwitchingToALegacyRequestDoesNotTouchIt() throws {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        harness.state.editorTab = .params
        let model = Model()
        let host = NSHostingView(rootView: Host(model: model).environment(harness.state))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        // Eski kayıt: parametre yalnızca tabloda. İstek değiştirmek eşitleme TETİKLEMEZ.
        var legacy = RequestModel(name: "eski", method: .get, url: "https://api.example.com/v1/legacy")
        legacy.queryParams = [KeyValueEntry(key: "name", value: "xyz")]
        model.request = legacy
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        XCTAssertEqual(model.request, legacy, "salt görüntülemek kaydı değiştirmemeli")
    }
}
