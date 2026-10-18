import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

@MainActor
final class WorkbenchStateTests: XCTestCase {
    private func settle(_ state: WorkbenchState, until condition: @escaping () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testTypingProducesFormattedOutputAndStats() async {
        let state = WorkbenchState()
        state.input = #"{"a":[1,2]}"#
        await settle(state) { !state.output.isEmpty }
        XCTAssertEqual(state.output, "{\n  \"a\": [\n    1,\n    2\n  ]\n}")
        XCTAssertEqual(state.validation, .valid)
        XCTAssertEqual(state.inputStats.lines, 1)
        XCTAssertEqual(state.outputStats.lines, 6)
    }

    /// 2026-10-18: 500 seviyeli girdi "Sort keys" ve XML → JSON'da uygulamayı
    /// çökertiyordu (iş 512 KB yığınlı thread'deydi). Artık `BackgroundWork`.
    func testDeeplyNestedInputDoesNotCrash() async {
        // Açık araç hatırlanıyor: sonraki testler JSON'la başlasın.
        defer { UserDefaults.standard.removeObject(forKey: "workbenchTool") }
        let state = WorkbenchState()
        state.select(toolID: "json")
        state.update(options: WorkbenchOptions(sortKeys: true))
        state.input = String(repeating: #"{"a":"#, count: 500) + "1" + String(repeating: "}", count: 500)
        await settle(state) { !state.output.isEmpty }
        XCTAssertFalse(state.output.isEmpty)

        state.select(toolID: "xml-to-json")
        state.input = String(repeating: "<a>", count: 500) + "1" + String(repeating: "</a>", count: 500)
        await settle(state) { !state.output.isEmpty }
        XCTAssertTrue(state.output.hasPrefix("{"))
    }

    func testTabsKeepTheirOwnInputAndAction() {
        let state = WorkbenchState()
        state.input = "birinci"
        let first = state.document.id
        state.newDocument()
        XCTAssertEqual(state.documents.count, 2)
        XCTAssertEqual(state.input, "")
        state.select(actionID: "minify")
        XCTAssertEqual(state.title(of: state.document), "JSON 2")

        state.select(documentID: first)
        XCTAssertEqual(state.input, "birinci")
        XCTAssertEqual(state.action.id, "format", "eylem sekmeye ait")
    }

    /// Sekmeler yalnızca JSON'da (kullanıcı kararı, 2026-10-19).
    func testOnlyJSONHasTabs() {
        defer { UserDefaults.standard.removeObject(forKey: "workbenchTool") }
        XCTAssertEqual(WorkbenchCatalog.all.filter(\.supportsTabs).map(\.id), ["json"])
        let state = WorkbenchState()
        state.select(toolID: "xml")
        state.newDocument()
        XCTAssertEqual(state.documents.count, 1, "sekmesiz araçta yeni sekme açılmaz")
    }

    func testTabNumbersUseTheSmallestFreeNumber() {
        let state = WorkbenchState()
        state.newDocument()
        state.newDocument()
        XCTAssertEqual(state.documents.map(\.number), [1, 2, 3])
        let second = state.documents[1].id
        state.closeDocument(second)
        state.newDocument()
        XCTAssertEqual(state.documents.map(\.number), [1, 3, 2], "boşalan 2 yeniden kullanılır")
        // Hepsi kapanınca yeniden 1.
        for doc in state.documents { state.closeDocument(doc.id) }
        XCTAssertEqual(state.documents.map(\.number), [1])
    }

    func testEditingATreeValueRewritesTheInput() async {
        let state = WorkbenchState()
        state.input = #"{"tutar":1,"ad":"Ali"}"#
        XCTAssertNil(state.editTreeValue(at: [.key("tutar")], text: "123"))
        XCTAssertEqual(state.input, "{\n  \"tutar\": 123,\n  \"ad\": \"Ali\"\n}")
        XCTAssertNotNil(state.editTreeValue(at: [.key("yok")], text: "1"))
    }

    func testClearCanBeUndone() {
        let state = WorkbenchState()
        state.input = "önemli"
        state.clearInput()
        XCTAssertEqual(state.input, "")
        XCTAssertNotNil(state.clearedInput)
        state.undoClear()
        XCTAssertEqual(state.input, "önemli")
        XCTAssertNil(state.clearedInput)
    }

    func testTypingAfterClearDropsTheUndo() {
        let state = WorkbenchState()
        state.input = "eski"
        state.clearInput()
        state.input = "yeni"
        XCTAssertNil(state.clearedInput)
    }

    func testOutputIsEditableOnlyWithThePencilAndRecomputeReplacesEdits() async {
        let state = WorkbenchState()
        state.input = "[1]"
        await settle(state) { !state.output.isEmpty }
        state.editOutput("elle")
        XCTAssertEqual(state.displayedOutput, state.output, "kalem kapalıyken düzenlenmez")

        state.toggleOutputEditing()
        state.editOutput("elle")
        XCTAssertEqual(state.displayedOutput, "elle")

        state.update(options: WorkbenchOptions(indentation: .fourSpaces))
        await settle(state) { state.output.contains("    1") }
        XCTAssertEqual(state.displayedOutput, state.output, "yeniden hesaplama düzenlemenin üzerine yazar")
    }

    func testEditingOutputUpdatesInputLiveWithoutRewritingOutput() async {
        // Kullanıcının denediği: çıktıda "tutar"ı değiştirince girdi de değişmeli.
        let state = WorkbenchState()
        state.input = #"{"tutar":1}"#
        await settle(state) { !state.output.isEmpty }
        state.toggleOutputEditing()
        let edited = "{\n  \"tutar\": 123\n}"
        state.editOutput(edited)
        XCTAssertEqual(state.input, edited, "girdi canlı güncellenmeli")
        await settle(state) { !state.isRunning }
        XCTAssertEqual(state.displayedOutput, edited, "yazılan çıktı ezilmemeli")
        XCTAssertEqual(state.validation, .valid)

        // Yazarken geçici olarak bozuk JSON da girdiye yansır; doğrulama hatayı gösterir.
        state.editOutput("{\n  \"tutar\": \n}")
        await settle(state) { if case .invalid = state.validation { return true }; return false }
        guard case .invalid = state.validation else { return XCTFail("bozuk girdi doğrulanmalı") }
        XCTAssertEqual(state.displayedOutput, "{\n  \"tutar\": \n}")
    }

    func testEditingEscapedOutputUnescapesIntoInput() async {
        let state = WorkbenchState()
        state.select(actionID: "escape")
        state.input = "a"
        await settle(state) { !state.output.isEmpty }
        state.toggleOutputEditing()
        state.editOutput(#""ab\nc""#)
        XCTAssertEqual(state.input, "ab\nc")
        state.editOutput(#""yarım"#)
        XCTAssertEqual(state.input, "ab\nc", "çözülemeyen ara hal girdiye yazılmaz")
    }

    func testTreeOnlyForFormat() {
        let state = WorkbenchState()
        state.select(outputMode: .tree)
        XCTAssertTrue(state.showsTree)
        state.select(actionID: "minify")
        XCTAssertFalse(state.showsTree)
        state.select(actionID: "format")
        XCTAssertFalse(state.showsTree, "başka eyleme geçince metne döner")
    }
}
