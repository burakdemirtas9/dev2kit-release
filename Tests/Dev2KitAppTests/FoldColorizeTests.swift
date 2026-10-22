import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı ekran görüntüsü (2026-10-22, Workbench çıktı): bir bloğu
/// katlayınca alttan görünür alana gelen satırlar renksiz kalıyordu;
/// renklendirme yalnızca görünen aralıkta ve kaydırınca yapılıyordu.
@MainActor
final class FoldColorizeTests: XCTestCase {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    /// Katlanan blok orta boy (~200 satır) ve sonrasında belge uzun kalıyor:
    /// kaydırma alanı değişmediği için eski kodda renklendirme hiç
    /// tetiklenmiyordu (kullanıcının dosyasında ölçüldü: 544 → 384 satır).
    func testLinesBroughtIntoViewByFoldingAreColorized() throws {
        let block = (0..<200).map { "      { \"id\" : \($0) }" }.joined(separator: ",\n")
        let tail = (0..<300).map { "    \"key\($0)\" : null" }.joined(separator: ",\n")
        let text = "{\n  \"list\" : [\n\(block)\n  ],\n  \"farKey\" : null,\n\(tail)\n}"
        let host = NSHostingView(rootView: CodeEditor(text: .constant(text), language: .json, isEditable: false, folding: CodeFoldingController()).frame(width: 420, height: 200))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let textView = try XCTUnwrap(find(NSTextView.self, in: host))
        let gutter = try XCTUnwrap(find(EditorGutter.self, in: host))
        let storage = try XCTUnwrap(textView.textStorage)
        let farKey = (text as NSString).range(of: "\"farKey\"").location + 1
        func color() -> NSColor? { storage.attribute(.foregroundColor, at: farKey, effectiveRange: nil) as? NSColor }
        XCTAssertNotEqual(color(), Theme.syntaxKey, "başta görünmüyor, boyanmamış olmalı (ön koşul)")

        gutter.onToggleFold?(1)   // "list" dizisi
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(color(), Theme.syntaxKey, "katlamayla görünür olan satır boyanmalı")
    }

    func testVisiblePiecesSkipFoldedRanges() {
        typealias C = CodeEditor.Coordinator
        XCTAssertEqual(C.visiblePieces(of: NSRange(location: 0, length: 100), excluding: []), [NSRange(location: 0, length: 100)])
        XCTAssertEqual(C.visiblePieces(of: NSRange(location: 0, length: 100), excluding: [NSRange(location: 60, length: 10), NSRange(location: 10, length: 20)]),
                       [NSRange(location: 0, length: 10), NSRange(location: 30, length: 30), NSRange(location: 70, length: 30)])
        XCTAssertEqual(C.visiblePieces(of: NSRange(location: 20, length: 10), excluding: [NSRange(location: 0, length: 100)]), [])
        XCTAssertEqual(C.visiblePieces(of: NSRange(location: 20, length: 30), excluding: [NSRange(location: 0, length: 25)]), [NSRange(location: 25, length: 25)])
    }

    final class Box: ObservableObject { @Published var text: String; init(_ text: String) { self.text = text } }
    struct Output: View {
        @ObservedObject var box: Box
        var body: some View { CodeEditor(text: $box.text, language: .json, isEditable: false, folding: CodeFoldingController()).frame(width: 420, height: 200) }
    }

    /// Workbench çıktısı biçimlendirmede yeniden yazılır; katlı kalan blok
    /// yeniden uygulanınca görünür alana gelen satırlar boyanmalı.
    func testOutputRewrittenWhileFoldedStaysColorized() throws {
        let items = (0..<4_000).map { "      { \"id\" : \($0) }" }.joined(separator: ",\n")
        let text = "{\n  \"list\" : [\n\(items)\n  ],\n  \"farKey\" : null\n}"
        let box = Box(text)
        let host = NSHostingView(rootView: Output(box: box))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let textView = try XCTUnwrap(find(NSTextView.self, in: host))
        let gutter = try XCTUnwrap(find(EditorGutter.self, in: host))
        gutter.onToggleFold?(1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // Yeniden biçimlendirme: aynı yapı, farklı metin (girdi değişti).
        box.text = text.replacingOccurrences(of: "\"farKey\" : null", with: "\"farKey\" : true")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let storage = try XCTUnwrap(textView.textStorage)
        let farKey = (textView.string as NSString).range(of: "\"farKey\"").location + 1
        XCTAssertEqual(storage.attribute(.foregroundColor, at: farKey, effectiveRange: nil) as? NSColor, Theme.syntaxKey,
                       "katlı çıktı yeniden yazılınca görünen satır boyanmalı")
    }
}
