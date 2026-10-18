import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı geri bildirimi (2026-10-19): başlık/parametre girişi Postman
/// gibi tablo olsun; en alttaki boş satıra yazınca satır oluşsun.
@MainActor
final class KeyValueTableTests: XCTestCase {
    final class Model: ObservableObject { @Published var entries: [KeyValueEntry] = [] }

    private struct Host: View {
        @ObservedObject var model: Model
        var body: some View {
            KeyValueEditor(entries: $model.entries, keyPlaceholder: "Header-Adi", valuePlaceholder: "değer")
                .frame(width: 700, height: 320)
        }
    }

    private func textFields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
    }

    func testTypingIntoTheDraftRowCreatesARowAndKeepsFocus() throws {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let model = Model()
        model.entries = [KeyValueEntry(key: "Accept", value: "application/json")]
        let host = NSHostingView(rootView: Host(model: model).environment(harness.state))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 700, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let draftKey = try XCTUnwrap(textFields(host).first { $0.placeholderString == "Header-Adi" }, "boş satır görünmeli")
        window.makeFirstResponder(draftKey)
        let editor = try XCTUnwrap(draftKey.currentEditor() as? NSTextView)
        editor.insertText("X-", replacementRange: editor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(model.entries.count, 2, "yazınca satır oluşur")

        // Odak aynı alanda kalmalı: ikinci parça aynı anahtara yazılır.
        let focused = try XCTUnwrap(window.firstResponder as? NSTextView, "odak kaybolmamalı")
        focused.insertText("Id", replacementRange: focused.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(model.entries.last?.key, "X-Id")
        XCTAssertNotNil(textFields(host).first { $0.placeholderString == "Header-Adi" }, "yeni boş satır açılır")

        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"],
           let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .nominalResolution]) {
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/table.png"))
        }
    }
}
