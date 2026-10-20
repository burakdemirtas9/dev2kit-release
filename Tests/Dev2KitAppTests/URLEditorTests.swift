import XCTest
import SwiftUI
import AppKit
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Adres düzenleyicisi: tek satır ↔ odakta sarılı, Enter gönderir, değere
/// satır sonu girmez. Ekran dışı pencerede (x: -5000) ölçülür.
@MainActor
final class URLEditorTests: XCTestCase {
    private final class Box {
        var text: String
        var submits = 0
        var rejections = 0
        var clicked: [String] = []
        init(_ text: String) { self.text = text }
    }

    private struct Host: View {
        let box: Box
        let limit: Int
        @State private var text: String
        @State private var editing = false

        init(box: Box, limit: Int) {
            self.box = box
            self.limit = limit
            _text = State(initialValue: box.text)
        }

        var body: some View {
            VStack(spacing: 0) {
                URLEditor(
                    text: Binding(get: { text }, set: { text = $0; box.text = $0 }),
                    isEditing: editing,
                    limit: limit,
                    definedVariables: [],
                    onSubmit: { box.submits += 1 },
                    onEditingChange: { value in DispatchQueue.main.async { editing = value } },
                    onLimitRejected: { box.rejections += 1 },
                    onVariableClick: { name, _, _ in box.clicked.append(name) }
                )
                Spacer(minLength: 0)
            }
            .frame(width: 400, height: 300)
        }
    }

    private var window: NSWindow!

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private func make(_ text: String, limit: Int = 1_000) -> (Box, AddressTextView, NSScrollView) {
        _ = NSApplication.shared
        let box = Box(text)
        let host = NSHostingView(rootView: Host(box: box, limit: limit))
        host.frame.size = NSSize(width: 400, height: 300)
        window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        spin()
        let textView = find(host)!
        return (box, textView, textView.enclosingScrollView!)
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func find(_ view: NSView) -> AddressTextView? {
        if let found = view as? AddressTextView { return found }
        for sub in view.subviews { if let found = find(sub) { return found } }
        return nil
    }

    private let long = "https://gw.ornek.test/" + String(repeating: "segment/", count: 30) + "{{base}}?x=1"

    func testFocusExpandsAndBlurCollapsesWithoutChangingValue() {
        let (box, textView, scrollView) = make(long)
        XCTAssertEqual(scrollView.frame.height, URLEditor.lineHeight, accuracy: 0.5)

        window.makeFirstResponder(textView)
        spin()
        XCTAssertGreaterThan(scrollView.frame.height, URLEditor.lineHeight + 10, "sığmayan adres odakta aşağı büyümeli")
        XCTAssertLessThanOrEqual(scrollView.frame.height, URLEditor.maxHeight)
        XCTAssertEqual(scrollView.frame.width, 400, accuracy: 0.5, "genişlik aynı kalmalı")

        window.makeFirstResponder(nil)
        spin()
        XCTAssertEqual(scrollView.frame.height, URLEditor.lineHeight, accuracy: 0.5)
        XCTAssertEqual(textView.string, long)
        XCTAssertEqual(box.text, long, "sarma yalnızca görsel")
    }

    func testShortAddressStaysSingleLineWhenFocused() {
        let (_, textView, scrollView) = make("https://a.test/x")
        window.makeFirstResponder(textView)
        spin()
        XCTAssertEqual(scrollView.frame.height, URLEditor.lineHeight, accuracy: 0.5)
    }

    func testEnterSubmitsWithoutInsertingNewline() {
        let (box, textView, _) = make("https://a.test")
        window.makeFirstResponder(textView)
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(box.submits, 1)
        XCTAssertEqual(textView.string, "https://a.test")
    }

    func testPastedNewlinesAreRemoved() {
        let (box, textView, _) = make("")
        window.makeFirstResponder(textView)
        textView.insertText("https://a.test/\n{{base}}\r\n/x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.string, "https://a.test/{{base}}/x")
        XCTAssertEqual(box.text, "https://a.test/{{base}}/x")
    }

    func testLimitRejectsBeforeInsert() {
        let (box, textView, _) = make("abc", limit: 5)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.insertText("defg", replacementRange: textView.selectedRange())
        spin(0.05)
        XCTAssertEqual(textView.string, "abc")
        XCTAssertEqual(box.rejections, 1)
    }

    func testHeightGrowsWithContentUpToMaximum() {
        XCTAssertEqual(URLEditor.height(for: "https://a.test", width: 400), URLEditor.lineHeight)
        let two = URLEditor.height(for: long, width: 400)
        XCTAssertGreaterThan(two, URLEditor.lineHeight)
        XCTAssertEqual(URLEditor.height(for: String(repeating: long, count: 20), width: 400), URLEditor.maxHeight)
    }

    /// Odak dışında değişkene tıklama o değişkeni bildirir (baloncuk /
    /// değer verme); düz metne tıklama bildirmez.
    func testClickOnVariableWhileCollapsedReportsName() throws {
        let (box, textView, _) = make("https://a.test/{{base}}/x")
        let layout = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let range = ("https://a.test/{{base}}/x" as NSString).range(of: "{{base}}")
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let origin = textView.textContainerOrigin
        let onVariable = NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
        XCTAssertEqual(textView.coordinator?.variable(at: onVariable)?.name, "base")
        XCTAssertNil(textView.coordinator?.variable(at: NSPoint(x: origin.x + 2, y: rect.midY + origin.y)))
        _ = box
    }

    // MARK: Tıklama (AppKit sırasıyla)
    //
    // NSWindow, ilk yanıtlayıcı olabilen görünüme tıklanınca onu `mouseDown`'dan
    // ÖNCE ilk yanıtlayıcı yapar. Eski kod "odakta değilse" diye baktığı için
    // değişken tıklaması hiç tutmuyordu (regresyon). Testler bu sırayı kurar:
    // önce `makeFirstResponder`, sonra `mouseDown`; izleme döngüsü mouseUp'ı
    // (ve varsa sürüklemeyi) süreç içi kuyruktan alır. Ekrana olay gönderilmez.

    private func textViewPoint(of needle: String, offset: Int = 2, in textView: AddressTextView) -> NSPoint {
        let layout = textView.layoutManager!, container = textView.textContainer!
        let range = (textView.string as NSString).range(of: needle)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location + offset, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let origin = textView.textContainerOrigin
        return NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
    }

    private func click(_ textView: AddressTextView, at point: NSPoint, dragTo end: NSPoint? = nil, clickCount: Int = 1) {
        func event(_ type: NSEvent.EventType, _ local: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: textView.convert(local, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
        }
        if let end { NSApp.postEvent(event(.leftMouseDragged, end), atStart: false) }
        NSApp.postEvent(event(.leftMouseUp, end ?? point), atStart: false)
        window.makeFirstResponder(textView)
        textView.mouseDown(with: event(.leftMouseDown, point))
        spin(0.4)
    }

    func testClickOnVariableWhileCollapsedOpensIt() {
        let (box, textView, _) = make("https://a.test/{{base}}/x")
        click(textView, at: textViewPoint(of: "{{base}}", in: textView))
        XCTAssertEqual(box.clicked, ["base"])
        XCTAssertEqual(textView.string, "https://a.test/{{base}}/x")
    }

    func testClickOnPlainTextDoesNotOpen() {
        let (box, textView, _) = make("https://a.test/{{base}}/x")
        click(textView, at: textViewPoint(of: "a.test", in: textView))
        XCTAssertEqual(box.clicked, [])
    }

    func testDragSelectionDoesNotOpen() {
        let (box, textView, _) = make("https://a.test/{{base}}/x")
        let start = textViewPoint(of: "{{base}}", offset: 1, in: textView)
        let end = textViewPoint(of: "{{base}}", offset: 6, in: textView)
        click(textView, at: start, dragTo: end)
        XCTAssertGreaterThan(textView.selectedRange().length, 0, "sürükleme seçmeli")
        XCTAssertEqual(box.clicked, [])
    }

    func testDoubleClickDoesNotOpen() {
        let (box, textView, _) = make("https://a.test/{{base}}/x")
        click(textView, at: textViewPoint(of: "{{base}}", in: textView), clickCount: 2)
        XCTAssertEqual(box.clicked, [])
    }

    /// Genişlemiş (sarılı) alanda ve satır sınırında bölünen değişkenin her
    /// iki parçası da aynı değişkeni açar.
    func testVariableSplitAcrossWrappedLinesOpensFromBothParts() throws {
        let name = "test-finance-overdraftaccount-bff-service-with-a-very-long-name"
        let text = String(repeating: "x", count: 30) + "{{\(name)}}/tail"
        let (box, textView, _) = make(text)
        window.makeFirstResponder(textView)
        spin()
        let layout = try XCTUnwrap(textView.layoutManager)
        let range = (text as NSString).range(of: "{{\(name)}}")
        let firstLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        let lastLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: NSMaxRange(range) - 1), effectiveRange: nil)
        XCTAssertNotEqual(firstLine.minY, lastLine.minY, "değişken iki satıra bölünmeli")

        click(textView, at: textViewPoint(of: "{{\(name)}}", offset: 3, in: textView))
        click(textView, at: textViewPoint(of: "{{\(name)}}", offset: range.length - 3, in: textView))
        XCTAssertEqual(box.clicked, [name, name])
    }

    /// Kaydırılmış içerikte tıklama alanı metinle hizalı kalır.
    func testClickAfterScrollingStillHitsVariable() {
        let text = String(repeating: "/segment", count: 60) + "/{{tail}}"
        let (box, textView, _) = make(text)
        window.makeFirstResponder(textView)
        spin()
        textView.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
        spin(0.1)
        click(textView, at: textViewPoint(of: "{{tail}}", in: textView))
        XCTAssertEqual(box.clicked, ["tail"])
    }

    /// Klavye: imleç değişkendeyken ⌥⏎ baloncuğu açar, değilse gönderir.
    func testOptionReturnOpensVariableAtCaret() {
        let (box, textView, _) = make("https://a.test/{{base}}/x")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 18, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        spin(0.1)
        XCTAssertEqual(box.clicked, ["base"])
        XCTAssertEqual(box.submits, 0)

        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(box.submits, 1)
    }
}
