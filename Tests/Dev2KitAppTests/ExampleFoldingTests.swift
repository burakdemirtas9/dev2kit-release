import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kenar çubuğunda response örneklerini katlama (kullanıcı isteği, 2026-10-28):
/// her isteğin örnekleri listeyi kalabalıklaştırıyordu. Örnekler varsayılan
/// olarak katlı; açılan istek hatırlanır; kaydedilen ya da açılan örnek görünür.
@MainActor
final class ExampleFoldingTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }

    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    override func setUp() {
        super.setUp()
        harness = AppStateHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
        super.tearDown()
    }

    // MARK: - Yardımcılar

    /// Örnekleri olan bir istek ekler (ağa çıkmadan).
    @discardableResult
    private func requestWithExamples(_ name: String, count: Int = 2) -> RequestModel {
        var request = harness.addRequest(named: name)
        request.examples = (0..<count).map { ResponseExample(name: "\(name) \($0)", statusCode: 200, body: "{}") }
        state.selectedRequest?.wrappedValue = request
        return request
    }

    private func visibleRows() -> [RequestTreeRows.Row] {
        RequestTreeRows.rows(for: state.workspace.collections.flatMap(\.requests), expanded: state.expandedExampleRequestIDs)
    }

    // MARK: - Davranış

    func testExamplesStartFolded() {
        let request = requestWithExamples("liste")
        XCTAssertFalse(state.areExamplesExpanded(request.id))
        XCTAssertFalse(visibleRows().contains { !$0.isRequest }, "örnek satırı görünmez")
    }

    func testToggleShowsAndHidesAndIsRemembered() {
        let request = requestWithExamples("liste")
        state.toggleExamples(request.id)
        XCTAssertEqual(visibleRows().filter { !$0.isRequest }.count, 2)

        state.waitForPendingWrites()
        let reopened = AppState(store: harness.store, secretStore: FileSecretStore())
        XCTAssertTrue(reopened.areExamplesExpanded(request.id), "açık istek yeniden açılışta hatırlanır")

        state.toggleExamples(request.id)
        XCTAssertFalse(visibleRows().contains { !$0.isRequest })
    }

    /// Katlanan isteğin örneği açıksa istek düzenleyicisine dönülür: gizlenen
    /// satır seçili kalmasın (macOS ağaç görünümü gibi).
    func testFoldingTheOpenExamplesRequestReturnsToTheRequest() throws {
        let request = requestWithExamples("liste")
        let ref = AppState.ExampleRef(requestID: request.id, exampleID: try XCTUnwrap(request.examples.first?.id))
        state.openExample(ref)
        XCTAssertTrue(state.areExamplesExpanded(request.id), "açılan örneğin satırı görünür")

        state.toggleExamples(request.id)
        XCTAssertNil(state.openExample)
        XCTAssertEqual(state.selectedRequestID, request.id)
    }

    /// Başka bir isteği katlamak açık örneğe dokunmaz.
    func testFoldingAnotherRequestKeepsTheOpenExample() throws {
        let open = requestWithExamples("açık")
        let other = requestWithExamples("diğer")
        state.toggleExamples(other.id)
        let ref = AppState.ExampleRef(requestID: open.id, exampleID: try XCTUnwrap(open.examples.first?.id))
        state.openExample(ref)

        state.toggleExamples(other.id)
        XCTAssertEqual(state.openExample, ref)
    }

    func testSavingAnExampleRevealsIt() async throws {
        let request = harness.addRequest(named: "liste")
        let data = ResponseData(statusCode: 200, headers: [("Content-Type", "application/json")],
                                body: Data(#"{"ok": true}"#.utf8), duration: 0.1, finalURL: nil)
        state.responses[request.id] = .success(AppState.makeDisplay(data))
        state.beginSavingExample(for: request.id)
        for _ in 0..<200 where state.pendingExampleSave?.phase == .preparing {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.commitPendingExample(name: "Dolu"), .added)
        XCTAssertTrue(state.areExamplesExpanded(request.id), "yeni örnek görünür")
    }

    /// Silinmiş isteklerin kimlikleri birikmez.
    func testForgottenRequestsAreDroppedOnLaunch() {
        let request = requestWithExamples("liste")
        state.toggleExamples(request.id)
        let ghost = UUID()
        UserDefaults.standard.set([request.id.uuidString, ghost.uuidString], forKey: AppState.expandedExamplesKey)
        state.waitForPendingWrites()

        let reopened = AppState(store: harness.store, secretStore: FileSecretStore())
        XCTAssertEqual(reopened.expandedExampleRequestIDs, [request.id])
    }

    // MARK: - Yerleşim (ölçülerek)

    private func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = tableView(in: subview) { return table }
        }
        return nil
    }

    /// Ok, satırları uzatmamalı: 22 pt'lik kare ok istek satırlarını 24'ten
    /// 30 pt'ye çıkarıyordu (ölçüldü). İstek satırları, oku olmayan örnek
    /// satırlarıyla aynı yükseklikte; açınca yalnızca örnek satırları eklenir.
    func testFoldArrowKeepsRowHeightsAndExpandingAddsOnlyExampleRows() throws {
        let withExamples = requestWithExamples("Örnekli")
        harness.addRequest(named: "Örneksiz")
        let host = NSHostingView(rootView: SidebarView().environment(state).frame(width: 320, height: 560))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 320, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let table = try XCTUnwrap(tableView(in: host), "kenar çubuğu listesi")
        let folded = (0..<table.numberOfRows).map { table.rect(ofRow: $0).height }

        state.toggleExamples(withExamples.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        // Satırlar: başlık, ilk istek, Örnekli, iki örnek, Örneksiz, "Yeni İstek".
        let expanded = (0..<table.numberOfRows).map { table.rect(ofRow: $0).height }
        XCTAssertEqual(expanded.count, folded.count + 2, "açınca iki örnek satırı eklenir")
        let requestAndExampleRows = expanded.dropFirst().dropLast()
        XCTAssertEqual(Set(requestAndExampleRows).count, 1,
                       "istek satırları (oklu/oksuz) ve örnek satırları aynı yükseklikte: \(expanded)")
    }
}
