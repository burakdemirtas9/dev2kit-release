import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp

/// 2026-10-18 çökmesi: ⌘Z ortak yığındaki silinmiş editörün kaydını
/// çağırıyordu (EXC_BAD_ACCESS, `_undoRedoTextOperation:`).
@MainActor
final class CodeEditorUndoTests: XCTestCase {
    func testEachEditorUsesItsOwnUndoManager() {
        let coordinator = CodeEditor.Coordinator(CodeEditor(text: .constant(""), language: .plain))
        let textView = NSTextView()
        textView.allowsUndo = true
        textView.delegate = coordinator
        XCTAssertTrue(textView.undoManager === coordinator.undoManager, "pencerenin ortak yığını değil, editörün kendi yığını")

        let other = CodeEditor.Coordinator(CodeEditor(text: .constant(""), language: .plain))
        XCTAssertFalse(coordinator.undoManager === other.undoManager, "iki editör yığın paylaşmaz")
    }

    func testTypingRegistersUndoOnTheEditorsOwnStack() {
        let coordinator = CodeEditor.Coordinator(CodeEditor(text: .constant(""), language: .plain))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let textView = NSTextView(frame: window.contentView!.bounds)
        textView.allowsUndo = true
        textView.delegate = coordinator
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)
        // Gruplamayı testte elle yönet: olay döngüsüne bağlı otomatik grup
        // açık kalırsa sonraki testlerde tutarsızlık hatası verir.
        coordinator.undoManager.groupsByEvent = false
        coordinator.undoManager.beginUndoGrouping()
        textView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
        coordinator.undoManager.endUndoGrouping()
        XCTAssertTrue(coordinator.undoManager.canUndo)
        XCTAssertFalse(window.undoManager?.canUndo ?? false, "ortak yığına kayıt düşmemeli")
    }
}
