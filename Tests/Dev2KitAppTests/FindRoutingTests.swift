import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp

/// API Client'ta ⌘F klavye odağındaki yerde arar (kullanıcı isteği,
/// 2026-10-20: yanıta tıklayıp ⌘F).
@MainActor
final class FindRoutingTests: XCTestCase {
    private func textView(_ pane: AppState.CodeEditorPane?) -> NSTextView {
        let view = NSTextView()
        view.identifier = pane.map { NSUserInterfaceItemIdentifier(rawValue: $0.rawValue) }
        return view
    }

    func testRoutesToFocusedEditorOrRequestSearch() {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let state = harness.state
        let (body, response, list) = (state.bodySearchRequest, state.responseSearchRequest, state.searchFocusRequest)

        state.findInAPIClient(firstResponder: textView(.response))
        XCTAssertEqual(state.responseSearchRequest, response + 1)

        state.findInAPIClient(firstResponder: textView(.body))
        XCTAssertEqual(state.bodySearchRequest, body + 1)

        state.findInAPIClient(firstResponder: textView(nil))
        state.findInAPIClient(firstResponder: nil)
        XCTAssertEqual(state.searchFocusRequest, list + 2, "metin alanı ya da odak yok: istek listesi")
        XCTAssertEqual(state.responseSearchRequest, response + 1)
        XCTAssertEqual(state.bodySearchRequest, body + 1)
    }

    func testEditorCarriesPaneIdentifier() throws {
        let host = NSHostingView(rootView: CodeEditor(
            text: .constant("{}"), language: .json, isEditable: false,
            paneIdentifier: AppState.CodeEditorPane.response.rawValue
        ))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        XCTAssertEqual(try XCTUnwrap(find(host)).identifier?.rawValue, AppState.CodeEditorPane.response.rawValue)
    }
}
