import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı kararı (2026-10-18): girdi başına 4 MB ve 16.000 satır; 1 MB'tan uzun satır
/// editörde gösterilmez (tek satırlık 5 MB uygulamayı 10 dk+ donduruyordu).
@MainActor
final class WorkbenchLimitsAppTests: XCTestCase {
    /// Beklenen mesajlar İngilizce.
    override func invokeTest() { withLanguage(.english) { super.invokeTest() } }

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
        var rejected: String?
        var longLine: String?
    }

    private func gate(_ recorder: Recorder) -> (CodeEditor.Coordinator, NSTextView) {
        let editor = CodeEditor(text: .constant(""), language: .plain, limits: EditorLimits(
            onRejected: { recorder.rejected = $0.localized },
            onLongLine: { recorder.longLine = $0 }
        ))
        return (editor.makeCoordinator(), NSTextView())
    }

    func testEditorRejectsChangesOverTheSizeLimit() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        let huge = String(repeating: "x\n", count: WorkbenchLimits.maxInputBytes / 2 + 10)
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: huge))
        XCTAssertEqual(recorder.rejected, WorkbenchLimits.tooLargeMessage(bytes: huge.utf8.count))
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

    // MARK: Satır sınırı (16.000, kullanıcı kararı)

    func testPasteOverTheLineLimitIsRejected() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        let lines = String(repeating: "x\n", count: WorkbenchLimits.maxInputLines) // 16.001 satır
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: lines))
        XCTAssertEqual(recorder.rejected, "Not added: the result would have 16,001 lines. The limit is 16,000 lines per input.")
    }

    /// Kullanıcı bulgusu (2026-10-18): ilk sürümde yalnız yeni satır
    /// engelleniyordu; sınırdaki metnin aynı satırına binlerce ekleme yapıldı.
    func testAtTheLineLimitNothingCanBeAddedButDeletingAndSameSizeEditsCan() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        textView.string = String(repeating: "x\n", count: WorkbenchLimits.maxInputLines - 1) + "son" // tam 16.000 satır
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: end, replacementString: "a"), "aynı satıra yazım da engellenir")
        XCTAssertEqual(recorder.rejected, "Not added: the input is at the 16,000-line limit. Delete something first.")
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "baş"), "metnin başına da")
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: end, replacementString: "\n"), "16.001. satır açılamaz")
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementString: ""), "silme serbest")
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementString: "y"), "aynı boyutta değiştirme serbest")
    }

    func testBelowTheLineLimitTypingIsFree() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        textView.string = String(repeating: "x\n", count: WorkbenchLimits.maxInputLines - 2) + "son" // 15.999 satır
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: end, replacementString: "a"))
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: end, replacementString: "\n"), "16.000. satır açılabilir")
        XCTAssertNil(recorder.rejected)
    }

    func testShrinkingReplacementThatAddsLinesIsStillCounted() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        textView.string = String(repeating: "x\n", count: WorkbenchLimits.maxInputLines - 1) + "abcdef" // 16.000 satır
        let last = NSRange(location: (textView.string as NSString).length - 6, length: 6)
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: last, replacementString: "a\nb"), "kısalsa da satır ekliyor")
    }

    func testCarriageReturnOnlyLinesCountToo() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        let lines = String(repeating: "x\r", count: WorkbenchLimits.maxInputLines)
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: lines))
    }

    func testFiveMBPasteIsRejectedEvenWithShortLines() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        let multi = String(repeating: #"{"id":1,"ad":"Müşteri"},"# + "\n", count: 200_000) // ~5 MB
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: multi))
        XCTAssertEqual(recorder.rejected, WorkbenchLimits.tooLargeMessage(bytes: multi.utf8.count))
    }

    func testEditorAllowsNormalTypingAndMultiLinePaste() {
        let recorder = Recorder()
        let (coordinator, textView) = gate(recorder)
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "a"))
        let multi = String(repeating: #"{"id":1,"ad":"Müşteri"},"# + "\n", count: 15_000) // 15.001 satır
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: multi))
        XCTAssertNil(recorder.rejected)
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

        // Biçimlenmiş çıktı 4 MB girdi sınırını aşıyor ama GÖSTERİLİR (20 MB'a
        // kadar); düzenlemek ve girdi yapmak girdiye yazdığı için reddedilir.
        state.select(actionID: "format")
        state.runNow()
        await settle { !state.outputHiddenFromEditor && !state.output.isEmpty }
        XCTAssertGreaterThan(state.output.utf8.count, WorkbenchLimits.maxInputBytes)
        XCTAssertFalse(state.outputHiddenFromEditor)
        state.toggleOutputEditing()
        XCTAssertFalse(state.isEditingOutput)
        XCTAssertEqual(state.limitNotice, WorkbenchLimits.outputEditIssue(state.output))
        let before = state.input
        state.useOutputAsInput()
        XCTAssertEqual(state.input, before, "girdi sınırını aşan çıktı girdi yapılmaz")
    }

    func testFormattedOutputOverTheLineLimitIsShownButNotEditableOrUsableAsInput() async {
        let state = WorkbenchState()
        state.select(toolID: "json")
        state.input = "[" + Array(repeating: #"{"a":1}"#, count: 6_000).joined(separator: ",") + "]" // 1 satır, ~54 KB
        await settle { !state.output.isEmpty }
        XCTAssertGreaterThan(state.outputStats.lines, WorkbenchLimits.maxInputLines)
        XCTAssertFalse(state.outputHiddenFromEditor, "çıktıya satır sınırı uygulanmaz")
        state.toggleOutputEditing()
        XCTAssertFalse(state.isEditingOutput)
        XCTAssertNotNil(state.limitNotice)
        let before = state.input
        state.useOutputAsInput()
        XCTAssertEqual(state.input, before)
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
        XCTAssertEqual(state.limitNotice, "Not added: the result would be 25 MB. The limit is 4.0 MB per input.")
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

    func testPastingThreeMBSingleLineDoesNotFreeze() async throws {
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
        input.insertText(singleLineJSON(bytes: 3 * 1_048_576), replacementRange: NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(state.inputHiddenFromEditor)
        XCTAssertEqual(input.string, "", "dev satır editöre girmemeli")
        XCTAssertGreaterThan(state.input.utf8.count, 3 * 1_048_576)
                XCTAssertLessThan(elapsed, 2.5, "eskiden 10 dakikadan uzun donuyordu")
    }
}
