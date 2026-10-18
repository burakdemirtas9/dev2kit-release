import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// 2026-10-18: başlık değerine 4 MB yapıştırmak uygulamayı dondurdu (tek
/// satırlık alan MB başına ~1,7 sn). Sınır metin alana GİRMEDEN uygulanmalı.
@MainActor
final class InputLimitTests: XCTestCase {
    final class Model: ObservableObject { @Published var text = "" }

    private struct Form: View {
        @ObservedObject var model: Model
        var body: some View {
            VStack {
                TextField("üst", text: .constant("")).frame(width: 300)
                TextField("değer", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .inputLimit(.headerValue)
                    .frame(width: 300)
            }
            .padding(20)
        }
    }

    private func textFields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
    }

    private func host(_ model: Model) throws -> (NSWindow, NSTextField) {
        let host = NSHostingView(rootView: Form(model: model))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let field = try XCTUnwrap(textFields(host).first { $0.formatter is LengthLimitFormatter }, "biçimleyici doğru alana takılmalı")
        return (window, field)
    }

    func testOnlyTheModifiedFieldGetsTheFormatter() throws {
        let (window, _) = try host(Model())
        defer { window.orderOut(nil) }
        let all = textFields(window.contentView!)
        XCTAssertEqual(all.filter { $0.formatter is LengthLimitFormatter }.count, 1)
        XCTAssertEqual(all.first { $0.placeholderString == "üst" }?.formatter == nil, true)
    }

    func testHugePasteIsRejectedBeforeItEntersTheField() throws {
        let model = Model()
        let (window, field) = try host(model)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        let start = Date()
        editor.insertText(String(repeating: "x", count: 4_000_000), replacementRange: NSRange(location: 0, length: 0))
        let elapsed = Date().timeIntervalSince(start)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(model.text, "")
        XCTAssertLessThan(elapsed, 0.2, "eskiden 4 MB ~7 sn donduruyordu")

        let jwt = "Bearer " + String(repeating: "eyJhbGciOiJSUzI1NiJ9.", count: 200) // ~4 KB: gerçek JWT boyu
        editor.insertText(jwt, replacementRange: NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(model.text, jwt, "sınırın altındaki değer girer")

        let rest = InputLimits.Field.headerValue.maxCharacters - jwt.utf16.count
        editor.insertText(String(repeating: "y", count: rest + 1), replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(model.text, jwt, "sınırı bir karakter aşan ekleme de girmez")
    }

    /// Başlık tablosu macOS'ta bir tablo görünümü: değiştirici her satırda
    /// DOĞRU alanı bulmalı (anahtar 256, değer 8 KB; environment değeri 64 KB).
    func testKeyValueRowsGetTheirOwnLimits() throws {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        for (valueLimit, expected) in [(InputLimits.Field.headerValue, 8_192), (.secretValue, 65_536)] {
            var entries = [KeyValueEntry(key: "a", value: "1"), KeyValueEntry(key: "b", value: "2")]
            let view = KeyValueEditor(entries: Binding(get: { entries }, set: { entries = $0 }),
                                      keyPlaceholder: "anahtar", valuePlaceholder: "değer", valueLimit: valueLimit)
                .environment(harness.state)
                .frame(width: 600, height: 300)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let limits = textFields(host).compactMap { ($0.formatter as? LengthLimitFormatter)?.limit }
            window.orderOut(nil)
            // İki satır ve en alttaki boş "yeni satır": hepsi sınırlı.
            XCTAssertEqual(limits.sorted(), [256, 256, 256, expected, expected, expected].sorted(), "\(valueLimit)")
        }
    }

    func testRowLimitIsEnforcedInTheModel() {
        XCTAssertEqual(InputLimits.tooManyRowsMessage, "En çok 1.000 satır eklenebilir.")
    }

    func testBypassPathsUseTheSameCheck() {
        XCTAssertNil(InputLimits.rejection(of: "a\nb", maxBytes: 10, maxLines: 2))
        XCTAssertEqual(InputLimits.rejection(of: String(repeating: "x", count: 11), maxBytes: 10, maxLines: 5), "Eklenmedi: metin 11 bytes; sınır 10 bytes.")
        XCTAssertEqual(InputLimits.rejection(of: "a\nb\nc", maxBytes: 100, maxLines: 2), "Eklenmedi: metin 3 satır; sınır 2 satır.")
    }

    func testLimitsTable() {
        XCTAssertEqual(InputLimits.Field.headerValue.maxCharacters, 8_192, "JWT sığmalı (1000 karakter bozuyordu)")
        XCTAssertEqual(InputLimits.maxRows, 1_000)
        XCTAssertEqual(InputLimits.tooLongMessage(.name), "Eklenmedi: bu alan en çok 200 karakter alır.")
        XCTAssertEqual(InputLimits.tooLongMessage(.search, english: true), "Not added: this field takes at most 256 characters.")
    }
}
