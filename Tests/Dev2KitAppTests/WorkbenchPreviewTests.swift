import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// HTML / Markdown Viewer (2026-11-01): solda düzenle, sağda önizleme.
/// Önizleme eyleminde çıktı bölmesi metin editörü değil, yalıtılmış web
/// görünümü; Markdown'ın "HTML" eylemi üretilen kodu editörde gösterir.
@MainActor
final class WorkbenchPreviewTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        UserDefaults.standard.removeObject(forKey: "workbenchTool")
    }

    private func settle(_ state: WorkbenchState, until condition: @escaping () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func pump(_ seconds: Double = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func host(_ state: WorkbenchState) -> NSView {
        let host = NSHostingView(rootView: WorkbenchView().environment(state).frame(width: 1100, height: 600))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1100, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
        pump()
        return host
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    func testMarkdownPreviewRendersInAWebViewInsteadOfAnEditor() async throws {
        let state = WorkbenchState()
        state.select(toolID: "markdown-viewer")
        state.input = "# Başlık\n\n- [x] bitti"
        await settle(state) { state.output.contains("<h1>") }
        XCTAssertTrue(state.output.contains("<h1>Başlık</h1>"))
        XCTAssertTrue(state.output.hasPrefix("<!DOCTYPE html>"), "önizleme tam belge çizer")

        let root = host(state)
        XCTAssertEqual(views(WKWebView.self, in: root).count, 1, "çıktı bölmesi önizleme")
        XCTAssertEqual(views(NSTextView.self, in: root).count, 1, "yalnızca girdi editörü")
    }

    func testMarkdownHTMLActionShowsGeneratedCodeInTheEditor() async throws {
        let state = WorkbenchState()
        state.select(toolID: "markdown-viewer")
        state.select(actionID: "html")
        state.input = "**kalın**"
        await settle(state) { !state.output.isEmpty }
        XCTAssertEqual(state.output, "<p><strong>kalın</strong></p>\n")

        let root = host(state)
        XCTAssertTrue(views(WKWebView.self, in: root).isEmpty)
        XCTAssertEqual(views(NSTextView.self, in: root).count, 2, "girdi ve çıktı editörü")
    }

    func testHTMLViewerShowsTheInputAsIs() async throws {
        let state = WorkbenchState()
        state.select(toolID: "html-viewer")
        state.input = "<p>merhaba</p>"
        await settle(state) { !state.output.isEmpty }
        XCTAssertEqual(state.output, "<p>merhaba</p>")
        let root = host(state)
        XCTAssertEqual(views(WKWebView.self, in: root).count, 1)
    }

    func testEmptyInputShowsNoPage() {
        let state = WorkbenchState()
        state.select(toolID: "markdown-viewer")
        let root = host(state)
        XCTAssertTrue(views(WKWebView.self, in: root).isEmpty, "boş belge zeminsiz beyaz sayfa olmasın")
    }
}
