import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı bildirimi (2026-10-22, ekran görüntüsü ve dosya): uzun değer
/// sarılınca devam satırları en soldan başlıyor, biçim bozulmuş gibi
/// görünüyordu. Devam satırı artık satırın girintisi + 2 karakterden başlar.
/// Sentetik veri.
@MainActor
final class WrapIndentTests: XCTestCase {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    private func editor(_ text: Binding<String>, editable: Bool = false, width: CGFloat = 420) throws -> (NSTextView, NSWindow) {
        let host = NSHostingView(rootView: CodeEditor(text: text, language: .json, isEditable: editable, folding: CodeFoldingController()).frame(width: width, height: 300))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (try XCTUnwrap(find(NSTextView.self, in: host)), window)
    }

    /// Satırın görünür parçaları: (x, karakter aralığı).
    private func fragments(ofLine line: Int, in textView: NSTextView) throws -> [(x: CGFloat, range: NSRange)] {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let string = textView.string as NSString
        var start = 0
        for _ in 0..<line { start = NSMaxRange(string.lineRange(for: NSRange(location: start, length: 0))) }
        let lineRange = string.lineRange(for: NSRange(location: start, length: 0))
        var result: [(CGFloat, NSRange)] = []
        var glyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
        let end = layoutManager.glyphIndexForCharacter(at: NSMaxRange(lineRange) - 1)
        while glyph <= end {
            var range = NSRange()
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &range)
            result.append((used.minX, layoutManager.characterRange(forGlyphRange: range, actualGlyphRange: nil)))
            glyph = NSMaxRange(range)
        }
        return result
    }

    func testWrappedValueContinuesFromTheLineIndent() throws {
        let token = String(repeating: "abcDEF123_", count: 40)
        let text = "{\n  \"Headers\" : {\n    \"X-Token\" :\n\"\(token)\",\n        \"X-Long\" : \"\(token)\"\n  }\n}"
        let (textView, window) = try editor(.constant(text))
        defer { window.orderOut(nil) }
        let font = try XCTUnwrap(textView.font)
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let width = try XCTUnwrap(textView.textContainer).size.width

        let indented = try fragments(ofLine: 4, in: textView)   // 8 boşlukla başlayan uzun satır
        XCTAssertGreaterThan(indented.count, 1, "satır sarılmalı")
        XCTAssertEqual(indented[0].x, 0, accuracy: 0.5, "ilk parça yerinde")
        for part in indented.dropFirst() {
            XCTAssertEqual(part.x, CGFloat(8 + 2) * space, accuracy: 1, "devam satırı girintiden: \(part)")
        }
        let flush = try fragments(ofLine: 3, in: textView)       // girintisiz uzun satır
        for part in flush.dropFirst() { XCTAssertEqual(part.x, 2 * space, accuracy: 1) }
        // Taşma yok.
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        XCTAssertLessThanOrEqual(layoutManager.usedRect(for: try XCTUnwrap(textView.textContainer)).width, width + 0.5)
        // Katlama altyapısı yerinde.
        XCTAssertTrue(layoutManager is FoldingLayoutManager)
        XCTAssertTrue(layoutManager.delegate is FoldingLayoutDelegate)
    }

    /// Önbellek düzenlemede düşer: uzun satırın ortasına satır sonu eklenince
    /// yeni satır en soldan başlar (devam satırı sanılmaz).
    func testInsertedLineBreakStartsAFreshLine() throws {
        let long = "    \"k\" : \"" + String(repeating: "x", count: 300) + "\""
        var text = "{\n" + long + "\n}"
        let binding = Binding(get: { text }, set: { text = $0 })
        let (textView, window) = try editor(binding, editable: true)
        defer { window.orderOut(nil) }
        XCTAssertGreaterThan(try fragments(ofLine: 1, in: textView).count, 1)
        let middle = 2 + 150
        textView.insertText("\n", replacementRange: NSRange(location: middle, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(try fragments(ofLine: 2, in: textView).first?.x ?? -1, 0, accuracy: 0.5)
    }

    /// Tek satırlık büyük metin: önbellek sayesinde doğrusal.
    func testHugeSingleLineLaysOutQuickly() throws {
        let text = "[" + (0..<40_000).map { "{\"id\":\($0),\"v\":\"abcdefgh\"}" }.joined(separator: ",") + "]"
        XCTAssertGreaterThan(text.utf8.count, 1_000_000)
        let (textView, window) = try editor(.constant(text))
        defer { window.orderOut(nil) }
        let start = Date()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
