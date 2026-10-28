import XCTest
import SwiftUI
import AppKit
@testable import Dev2KitApp
@testable import Dev2KitCore

/// İstek gövdesinde `{{değişken}}` (kullanıcı isteği, 2026-10-28): adres,
/// header ve param alanlarındaki gibi renkli; tıklanınca (ve ⌥⏎ ile) aynı
/// baloncuk. Yalnızca API Client gövdesi; `variables` verilmeyen editör
/// (Workbench, yanıt) eskisi gibi. Ekran dışı pencerede (x: -5000) ölçülür;
/// tıklama AppKit sırasıyla kurulur (bkz. `URLEditorTests`).
@MainActor
final class BodyVariableTests: XCTestCase {
    private final class Model: ObservableObject {
        @Published var text: String
        @Published var defined: TemplateVariables.DefinedNames
        var clicked: [String] = []

        init(_ text: String, defined: [String]) {
            self.text = text
            self.defined = TemplateVariables.DefinedNames(environment: nil, tokenVariables: defined, secretNames: [])
        }
    }

    private struct Host: View {
        @ObservedObject var model: Model
        let withVariables: Bool
        let language: CodeLanguage

        var body: some View {
            CodeEditor(
                text: $model.text,
                language: language,
                variables: withVariables
                    ? CodeEditorVariables(defined: model.defined, onClick: { name, _, _ in model.clicked.append(name) })
                    : nil
            )
            .frame(width: 500, height: 300)
        }
    }

    private let body = "{\n  \"test\": \"{{token4}}\",\n  \"other\": \"{{yok}}\",\n  \"plain\": \"metin\"\n}"
    private var window: NSWindow!

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private func make(_ text: String? = nil, defined: [String] = ["token4"], withVariables: Bool = true,
                      language: CodeLanguage = .json) -> (Model, CodeTextView) {
        _ = NSApplication.shared
        let model = Model(text ?? body, defined: defined)
        let host = NSHostingView(rootView: Host(model: model, withVariables: withVariables, language: language))
        host.frame.size = NSSize(width: 500, height: 300)
        window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        spin()
        let textView = find(host)!
        paintVisibleRegion(textView)
        return (model, textView)
    }

    /// Editör yalnızca görünen bölgeyi boyar; ekran dışı test penceresinde
    /// ilk boyama kaydırma bildirimiyle gelir (bkz. `FoldColorizeTests`).
    /// Kaydırmanın gönderdiği bildirim gönderilir.
    private func paintVisibleRegion(_ textView: NSTextView) {
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
        spin(0.1)
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func find(_ view: NSView) -> CodeTextView? {
        if let found = view as? CodeTextView { return found }
        for sub in view.subviews { if let found = find(sub) { return found } }
        return nil
    }

    private func attribute(_ key: NSAttributedString.Key, of needle: String, offset: Int = 2, in textView: NSTextView) -> NSColor? {
        let range = (textView.string as NSString).range(of: needle)
        return textView.textStorage?.attribute(key, at: range.location + offset, effectiveRange: nil) as? NSColor
    }

    private func point(of needle: String, offset: Int = 3, in textView: NSTextView) -> NSPoint {
        let layout = textView.layoutManager!, container = textView.textContainer!
        let range = (textView.string as NSString).range(of: needle)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location + offset, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let origin = textView.textContainerOrigin
        return NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
    }

    private func click(_ textView: NSTextView, at point: NSPoint, dragTo end: NSPoint? = nil, clickCount: Int = 1) {
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

    // MARK: - Renk

    /// Tanımlı değişken mor, tanımsız kırmızı (adres alanıyla aynı renk ve
    /// zemin); string'in geri kalanı sözdizimi renginde.
    func testVariablesAreColoredLikeTheAddressField() {
        let (_, textView) = make()
        XCTAssertEqual(attribute(.foregroundColor, of: "{{token4}}", in: textView), Theme.variableNS)
        XCTAssertEqual(attribute(.backgroundColor, of: "{{token4}}", in: textView), Theme.variableBackgroundNS)
        XCTAssertEqual(attribute(.foregroundColor, of: "{{yok}}", in: textView), Theme.undefinedVariableNS)
        XCTAssertEqual(attribute(.backgroundColor, of: "{{yok}}", in: textView), Theme.undefinedVariableBackgroundNS)
        XCTAssertEqual(attribute(.foregroundColor, of: "metin", in: textView), Theme.syntaxString)
        XCTAssertNil(attribute(.backgroundColor, of: "metin", in: textView))
    }

    /// Environment değişince (değer kaydedildi, secret eklendi) yeniden boyanır.
    func testDefiningTheVariableRecolorsIt() {
        let (model, textView) = make()
        model.defined = TemplateVariables.DefinedNames(environment: nil, tokenVariables: ["token4", "yok"], secretNames: [])
        spin()
        XCTAssertEqual(attribute(.foregroundColor, of: "{{yok}}", in: textView), Theme.variableNS)
    }

    /// Yazarak değişken bozulunca zemini kalmaz; düz metinde de renk sıfırlanır.
    func testEditingAwayTheVariableClearsItsColor() {
        let (_, textView) = make("{{a}} metin", defined: ["a"], language: .plain)
        XCTAssertEqual(attribute(.foregroundColor, of: "{{a}}", in: textView), Theme.variableNS)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 4, length: 1))   // ikinci "}"
        textView.insertText("", replacementRange: textView.selectedRange())
        spin(0.1)
        XCTAssertEqual(textView.string, "{{a} metin")
        XCTAssertNil(textView.textStorage?.attribute(.backgroundColor, at: 2, effectiveRange: nil))
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor, Theme.editorText)
    }

    /// Workbench ve yanıt editörü (`variables` yok): eskisi gibi, değişken
    /// yalnızca metin; tıklama bir şey açmaz.
    func testEditorWithoutVariablesIsUnchanged() {
        let (model, textView) = make(withVariables: false)
        XCTAssertEqual(attribute(.foregroundColor, of: "{{token4}}", in: textView), Theme.syntaxString)
        XCTAssertNil(attribute(.backgroundColor, of: "{{token4}}", in: textView))
        XCTAssertNil(textView.onVariableClick)
        click(textView, at: point(of: "{{token4}}", in: textView))
        XCTAssertEqual(model.clicked, [])
    }

    // MARK: - Tıklama

    func testClickOnVariableOpensIt() {
        let (model, textView) = make()
        click(textView, at: point(of: "{{token4}}", in: textView))
        click(textView, at: point(of: "{{yok}}", in: textView))
        XCTAssertEqual(model.clicked, ["token4", "yok"])
        XCTAssertEqual(textView.string, body, "tıklama metni değiştirmez")
    }

    func testClickOnPlainTextDragAndDoubleClickDoNotOpen() {
        let (model, textView) = make()
        click(textView, at: point(of: "metin", in: textView))
        click(textView, at: point(of: "{{token4}}", offset: 1, in: textView),
              dragTo: point(of: "{{token4}}", offset: 7, in: textView))
        XCTAssertGreaterThan(textView.selectedRange().length, 0, "sürükleme seçmeli")
        click(textView, at: point(of: "{{token4}}", in: textView), clickCount: 2)
        XCTAssertEqual(model.clicked, [])
    }

    /// Klavye: imleç değişkendeyken ⌥⏎ baloncuğu açar; değilse olağan satır sonu.
    func testOptionReturnOpensVariableAtCaret() {
        let (model, textView) = make()
        window.makeFirstResponder(textView)
        let inside = (body as NSString).range(of: "{{token4}}").location + 4
        textView.setSelectedRange(NSRange(location: inside, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        spin(0.1)
        XCTAssertEqual(model.clicked, ["token4"])
        XCTAssertEqual(textView.string, body)

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertNotEqual(textView.string, body, "değişken dışında satır sonu eklenir")
    }

    // MARK: - Kural (yalnızca tıklanan satır taranır)

    func testHitTestingFindsTheVariableOnItsLineOnly() {
        let text = "satır bir\n  \"a\": \"{{ilk}}\",\nüç {{ikinci}} son"
        let ns = text as NSString
        let first = ns.range(of: "{{ilk}}")
        let second = ns.range(of: "{{ikinci}}")
        XCTAssertEqual(VariableHitTesting.variable(containing: first.location, in: text),
                       .init(name: "ilk", range: first, index: first.location))
        XCTAssertEqual(VariableHitTesting.variable(containing: NSMaxRange(second) - 1, in: text)?.range, second)
        XCTAssertNil(VariableHitTesting.variable(containing: NSMaxRange(first), in: text), "kapanıştan sonrası değişken değil")
        XCTAssertNil(VariableHitTesting.variable(containing: 0, in: text))
        XCTAssertNil(VariableHitTesting.variable(containing: ns.length, in: text))
        XCTAssertNil(VariableHitTesting.variable(containing: -1, in: text))
    }
}
