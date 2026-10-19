import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp

/// Kullanıcı isteği (2026-10-19): "tümünü katla"dan sonra açılış adım adım
/// olsun; katlı blokta "… N keys/items" özeti görünsün.
@MainActor
final class StepwiseFoldingTests: XCTestCase {
    private let json = """
    {
      "user": {
        "id": 42,
        "roles": [
          "admin",
          "dev"
        ]
      },
      "items": [
        { "id": 1 },
        { "id": 2 }
      ]
    }
    """

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    func testCollapseAllThenOpeningTheRootKeepsChildrenFolded() throws {
        let controller = CodeFoldingController()
        let host = NSHostingView(rootView: CodeEditor(text: .constant(json), language: .json, isEditable: false, folding: controller).frame(width: 500, height: 300))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let textView = try XCTUnwrap(find(NSTextView.self, in: host))
        let folding = try XCTUnwrap(textView.layoutManager?.delegate as? FoldingLayoutDelegate)
        let gutter = try XCTUnwrap(find(EditorGutter.self, in: host))

        controller.collapseAll()
        XCTAssertEqual(gutter.foldedLines, [0, 1, 3, 8], "iç içe olanlar dahil hepsi katlı (satırlar 0'dan)")
        XCTAssertEqual(Array(folding.placeholders.values), ["… 2 keys"], "yalnızca görünen (kök) özet alır")

        gutter.onToggleFold?(0)
        XCTAssertEqual(gutter.foldedLines, [1, 3, 8], "kök açıldı, çocuklar katlı kaldı")
        XCTAssertEqual(Set(folding.placeholders.values), ["… 2 keys", "… 2 items"])

        gutter.onToggleFold?(1)
        XCTAssertEqual(gutter.foldedLines, [3, 8], "user açıldı; içindeki roles hâlâ katlı")
        XCTAssertEqual(folding.placeholders.count, 2)
    }

    func testHiddenLookupUsesSortedRanges() {
        let delegate = FoldingLayoutDelegate()
        delegate.hiddenRanges = [NSRange(location: 50, length: 10), NSRange(location: 5, length: 5), NSRange(location: 20, length: 1)]
        XCTAssertTrue(delegate.isHidden(5))
        XCTAssertTrue(delegate.isHidden(9))
        XCTAssertFalse(delegate.isHidden(10))
        XCTAssertTrue(delegate.isHidden(20))
        XCTAssertFalse(delegate.isHidden(21))
        XCTAssertTrue(delegate.isHidden(59))
        XCTAssertFalse(delegate.isHidden(60))
        XCTAssertFalse(delegate.isHidden(0))
    }
}
