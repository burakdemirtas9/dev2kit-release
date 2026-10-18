import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı kararı (2026-10-18): girdi başına 20 MB; 2 MB'tan uzun satır
/// editörde gösterilmez (tek satırlık 5 MB uygulamayı 10 dk+ donduruyordu).
@MainActor
final class WorkbenchLimitsAppTests: XCTestCase {
    private func singleLineJSON(bytes: Int) -> String {
        let row = #"{"id":1,"ad":"Müşteri"},"#
        return "[" + String(repeating: row, count: bytes / row.utf8.count + 1) + "1]"
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "workbenchTool")
    }

    // MARK: Editör kapısı

    private final class Recorder {
        var tooLarge: Int?
        var longLine: String?
    }

    private func gate(_ recorder: Recorder) -> (CodeEditor.Coordinator, NSTextView) {
        let editor = CodeEditor(text: .constant(""), language: .plain, limits: EditorLimits(
            onTooLarge: { recorder.tooLarge = $0 },
            onLongLine: { recorder.longLine = $0 }
        ))
        return (editor.makeCoordinator(), NSTextView())
    }

    func testEditorRejectsChangesOverTheSizeLimit() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        let huge = String(repeating: "x\n", count: WorkbenchLimits.maxInputBytes / 2 + 10)
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: huge))
        XCTAssertEqual(recorder.tooLarge, huge.utf8.count)
        XCTAssertNil(recorder.longLine)
    }

    func testEditorHandsLongLinePasteToTheCallerInsteadOfInsertingIt() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        textView.string = "önce "
        let line = singleLineJSON(bytes: WorkbenchLimits.maxEditorLineBytes + 100)
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementString: line))
        XCTAssertEqual(recorder.longLine, "önce " + line, "tam sonuç metni verilmeli")
        XCTAssertEqual(textView.string, "önce ", "editöre girmemeli")
    }

    func testEditorAllowsNormalTypingAndMultiLinePaste() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "a"))
        let multi = String(repeating: #"{"id":1,"ad":"Müşteri"},"# + "\n", count: 200_000) // ~5 MB, kısa satırlar
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: multi))
        XCTAssertNil(recorder.tooLarge)
        XCTAssertNil(recorder.longLine)
    }

    // MARK: Workbench

    func testLongLineInputIsKeptHiddenAndToolsStillWork() async {
        let state = WorkbenchState()
        state.select(toolID: "json")
        state.acceptInputHiddenFromEditor(singleLineJSON(bytes: 3 * 1_048_576))
        XCTAssertTrue(state.inputHiddenFromEditor)
        state.runNow()
        await settle { !state.output.isEmpty }
        XCTAssertFalse(state.outputHiddenFromEditor, "Format çıktısı çok satırlı: gösterilir")

        state.select(actionID: "minify")
        state.runNow()
        await settle { state.outputHiddenFromEditor }
        XCTAssertTrue(state.outputHiddenFromEditor, "Minify çıktısı tek satır: gösterilmez")
        state.toggleOutputEditing()
        XCTAssertFalse(state.isEditingOutput, "gizli çıktı düzenlenemez")

        state.select(actionID: "format")
        state.runNow()
        await settle { !state.outputHiddenFromEditor && !state.output.isEmpty }
        state.useOutputAsInput()
        XCTAssertFalse(state.inputHiddenFromEditor, "biçimlenmiş girdi editörde gösterilir")
    }

    func testHiddenFlagIsPerTab() {
        let state = WorkbenchState()
        state.select(toolID: "json")
        state.acceptInputHiddenFromEditor(singleLineJSON(bytes: 3 * 1_048_576))
        state.newDocument()
        XCTAssertFalse(state.inputHiddenFromEditor)
        state.select(documentID: state.documents[0].id)
        XCTAssertTrue(state.inputHiddenFromEditor)
    }

    func testLimitNoticeIsShown() {
        let state = WorkbenchState()
        state.reportLimit(WorkbenchLimits.tooLargeMessage(bytes: 25_400_000))
        XCTAssertEqual(state.limitNotice, "Not added: the result would be 25 MB. The limit is 20 MB per input.")
    }

    // MARK: Diff Checker

    func testDiffSideWithLongLineIsHiddenAndSwapCarriesTheFlag() {
        let diff = DiffCheckerState()
        diff.left = singleLineJSON(bytes: 3 * 1_048_576)
        diff.right = "[1]"
        XCTAssertTrue(diff.document.leftTooLargeForEditor)
        XCTAssertFalse(diff.document.rightTooLargeForEditor)
        diff.swapSides()
        XCTAssertFalse(diff.document.leftTooLargeForEditor)
        XCTAssertTrue(diff.document.rightTooLargeForEditor)
    }

    // MARK: Uçtan uca: gerçek editöre yapıştırma

    private func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    func testPastingFiveMBSingleLineDoesNotFreeze() async throws {
        let state = WorkbenchState()
        state.select(toolID: "json")
        let host = NSHostingView(rootView: WorkbenchView().environment(state).frame(width: 1000, height: 600))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let input = try XCTUnwrap(textViews(host).first { $0.isEditable }, "girdi editörü")

        let start = Date()
        input.insertText(singleLineJSON(bytes: 5 * 1_048_576), replacementRange: NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(state.inputHiddenFromEditor)
        XCTAssertEqual(input.string, "", "dev satır editöre girmemeli")
        XCTAssertGreaterThan(state.input.utf8.count, 5 * 1_048_576)
        print("PROBE paste 5MB: \(Int(elapsed * 1000)) ms (0,5 sn bekleme dahil)")
        XCTAssertLessThan(elapsed, 2.5, "eskiden 10 dakikadan uzun donuyordu")
    }
}
