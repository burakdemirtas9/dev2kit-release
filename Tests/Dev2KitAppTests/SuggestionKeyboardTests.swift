import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// `{{` önerilerinde klavye (kullanıcı isteği, 2026-11-01): ↑/↓ gezinir,
/// ⏎ seçer, Esc kapatır. Gerçek klavye olaylarıyla, iki alan türünde:
/// header/param hücresi (SwiftUI `TextField`) ve adres alanı (`NSTextView`).
@MainActor
final class SuggestionKeyboardTests: XCTestCase {
    private var harness: AppStateHarness!
    private var window: NSWindow!
    private var submits = 0

    /// Uygulamadaki gibi `@Observable` (alanlar `AppState`'e bağlı).
    /// `ObservableObject` ile ⏎'deki yazım SwiftUI'nin "Publishing changes
    /// from within view updates" uyarısını veriyordu; uygulamada o yol yok.
    /// (`private` olamaz: makronun ürettiği uzantı erişemiyor.)
    @Observable final class Model { var text = "" }

    override func setUp() async throws {
        harness = AppStateHarness()
        _ = harness.state.addEnvironment()
        harness.state.workspace.environments[0].variables = [
            KeyValueEntry(key: "baseUrl", value: "https://a.test"),
            KeyValueEntry(key: "token", value: "t"),
            KeyValueEntry(key: "tenant", value: "x"),
        ]
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        harness.tearDown()
        harness = nil
    }

    private func pump(_ seconds: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func host(_ model: Model, address: Bool) {
        struct Host: View {
            @Bindable var model: Model
            let address: Bool
            let onSubmit: () -> Void
            var body: some View {
                TemplateTextField(
                    placeholder: "", text: $model.text, limit: address ? .url : .headerValue,
                    bordered: !address ? false : true, onSubmit: onSubmit,
                    capsuleLeading: address ? AnyView(Text("GET")) : nil
                )
                .frame(width: 500, height: 220, alignment: .top)
            }
        }
        let view = NSHostingView(rootView: Host(model: model, address: address) { [unowned self] in submits += 1 }
            .environment(harness.state))
        window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 500, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        pump(0.5)
    }

    private func editors(_ view: NSView) -> [NSView] {
        var result: [NSView] = []
        if view is NSTextField || view is NSTextView { result.append(view) }
        for sub in view.subviews { result += editors(sub) }
        return result
    }

    /// Alanı odaklar ve `{{` yazar (alan düzenleyicisine metin girişi).
    private func focusAndType(_ text: String) throws {
        let target = try XCTUnwrap(editors(window.contentView!).first { ($0 as? NSTextField)?.isEditable == true || $0 is NSTextView })
        window.makeFirstResponder(target)
        pump()
        let editor = try XCTUnwrap((window.firstResponder as? NSTextView) ?? (target as? NSTextField)?.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: editor.selectedRange())
        pump()
    }

    private func key(_ code: UInt16, _ characters: String) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )!)
        }
        pump()
    }

    private let down: (UInt16, String) = (125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
    private let up: (UInt16, String) = (126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
    private let enter: (UInt16, String) = (36, "\r")
    private let escape: (UInt16, String) = (53, "\u{1b}")

    func testArrowsAndReturnInAHeaderField() throws {
        let model = Model()
        host(model, address: false)
        try focusAndType("Bearer {{t")          // öneriler: token, tenant
        key(down.0, down.1)                      // token → tenant
        key(enter.0, enter.1)
        XCTAssertEqual(model.text, "Bearer {{tenant}}")

        model.text = ""
        pump()
        try focusAndType("{{")                   // baseUrl, token, tenant
        key(up.0, up.1)                          // başa sarar: sondaki tenant
        key(enter.0, enter.1)
        XCTAssertEqual(model.text, "{{tenant}}")
    }

    func testEscapeClosesTheListAndReturnThenBehavesNormally() throws {
        let model = Model()
        host(model, address: true)
        try focusAndType("https://x.test/{{to")
        key(escape.0, escape.1)
        XCTAssertEqual(submits, 0, "Esc yalnızca listeyi kapatır")
        key(enter.0, enter.1)
        XCTAssertEqual(model.text, "https://x.test/{{to", "liste kapalı: ⏎ tamamlamaz")
        XCTAssertEqual(submits, 1, "liste kapalıyken ⏎ her zamanki gibi gönderir")
    }

    func testArrowsAndReturnInTheAddressField() throws {
        let model = Model()
        host(model, address: true)
        try focusAndType("{{")
        key(down.0, down.1)                      // baseUrl → token
        key(enter.0, enter.1)
        XCTAssertEqual(model.text, "{{token}}")
        XCTAssertEqual(submits, 0, "öneri açıkken ⏎ göndermez, tamamlar")
    }
}
