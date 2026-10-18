import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

@MainActor
final class DiffCheckerStateTests: XCTestCase {
    private func settle(_ condition: @escaping () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testComparesJSONSemanticallyAndByLines() async {
        let state = DiffCheckerState()
        state.left = #"{"a":1,"b":"x"}"#
        state.right = #"{"b":"y","a":1}"#
        await settle { state.result != nil && !state.isRunning }
        XCTAssertEqual(state.result?.jsonChanges?.map(\.path), ["b"])
        XCTAssertTrue(state.showsChanges, "JSON'da varsayılan liste görünümü")
        state.select(resultMode: .lines)
        XCTAssertFalse(state.showsChanges)
        XCTAssertEqual(state.result?.added, 1)
    }

    func testLanguageAndOptionsRecompute() async {
        let state = DiffCheckerState()
        state.select(language: .text)
        state.left = "A"
        state.right = "a"
        await settle { state.result?.isIdentical == false }
        var options = state.document.options
        options.line.ignoreCase = true
        state.update(options: options)
        await settle { state.result?.isIdentical == true }
        XCTAssertEqual(state.result?.isIdentical, true)
    }

    func testSwapNavigationAndTabs() async {
        let state = DiffCheckerState()
        state.select(language: .text)
        state.left = "a\nb\nc\nd"
        state.right = "a\nB\nc\nD"
        await settle { state.result?.changeStarts.count == 2 }
        XCTAssertEqual(state.moveToChange(forward: true), 1)
        XCTAssertEqual(state.moveToChange(forward: true), 3)
        XCTAssertEqual(state.moveToChange(forward: true), 1, "uçta başa sarar")
        XCTAssertEqual(state.moveToChange(forward: false), 3)

        state.swapSides()
        XCTAssertEqual(state.left, "a\nB\nc\nD")

        let first = state.document.id
        state.newDocument()
        XCTAssertEqual(state.title(of: state.document), "Diff 2")
        XCTAssertEqual(state.left, "")
        state.select(documentID: first)
        XCTAssertEqual(state.right, "a\nb\nc\nd")
        for doc in state.documents { state.closeDocument(doc.id) }
        XCTAssertEqual(state.documents.map(\.number), [1])
    }

    func testLargeInputWaitsForRun() {
        let state = DiffCheckerState()
        state.left = String(repeating: "a\n", count: DiffCheckerState.autoRunLimit)
        XCTAssertTrue(state.isLarge)
        XCTAssertTrue(state.isStale)
        XCTAssertFalse(state.isRunning)
    }

    func testWorkbenchRoutesToDiffChecker() {
        let workbench = WorkbenchState()
        workbench.select(toolID: WorkbenchCatalog.diffCheckerID)
        XCTAssertTrue(workbench.showsDiffChecker)
        workbench.select(toolID: "json")
        XCTAssertFalse(workbench.showsDiffChecker)
    }
}
