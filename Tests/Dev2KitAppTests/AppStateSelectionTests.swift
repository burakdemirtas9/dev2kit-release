import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Seçim ve sekme kuralları: tekil seçim, çoklu seçim ve sekmelerin izlediği yol.
@MainActor
final class AppStateSelectionTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }

    override func setUp() {
        super.setUp()
        harness = AppStateHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
        super.tearDown()
    }

    private func threeRequests() -> [RequestModel] {
        ["a", "b", "c"].map { harness.addRequest(named: $0) }
    }

    // MARK: - Tekil seçim

    func testSelectingRequestKeepsSingleSelection() {
        let requests = threeRequests()
        state.selectedRequestID = requests[0].id
        XCTAssertEqual(state.selectedRequestIDs, [requests[0].id],
                       "tekil seçim çoklu seçimi de sıfırlamalı")
    }

    // MARK: - Çoklu seçim

    func testApplySelectionKeepsActiveWhenStillSelected() {
        let requests = threeRequests()
        let order = requests.map(\.id)
        state.selectedRequestID = requests[1].id

        state.applySelection(Set(order), order: order)

        XCTAssertEqual(state.selectedRequestID, requests[1].id,
                       "seçim genişlerken sağdaki panel yerinden oynamamalı")
        XCTAssertEqual(state.selectedRequestIDs.count, 3)
    }

    func testApplySelectionMovesActiveWhenItDropsOut() {
        let requests = threeRequests()
        let order = requests.map(\.id)
        state.selectedRequestID = requests[2].id

        state.applySelection([requests[0].id, requests[1].id], order: order)

        XCTAssertEqual(state.selectedRequestID, requests[1].id,
                       "kümedeki son istek aktif olmalı")
    }

    func testDeletingSelectedRequestsClearsThemFromSelection() {
        let requests = threeRequests()
        let order = requests.map(\.id)
        state.applySelection(Set(order), order: order)

        state.deleteRequests([requests[0].id, requests[1].id])

        XCTAssertEqual(state.selectedRequestIDs, [requests[2].id])
    }

    // MARK: - Sekmeler

    func testSelectingOpensPreviewTabAndReplacesIt() {
        let requests = threeRequests()
        // Yeni istekler kalıcı sekme; seçimle açılan önizleme sekmesi ayrı.
        state.closeTabsToRight(of: requests[0].id)
        state.selectedRequestID = requests[1].id
        let preview = state.previewTabID
        XCTAssertEqual(preview, requests[1].id)

        state.selectedRequestID = requests[2].id
        XCTAssertEqual(state.previewTabID, requests[2].id, "önizleme sekmesi yer değiştirmeli")
        XCTAssertFalse(state.openTabs.contains(requests[1].id), "önceki önizleme kapanmalı")
    }

    func testPinnedTabSurvivesNextSelection() {
        let requests = threeRequests()
        state.selectedRequestID = requests[1].id
        state.pinTab(requests[1].id)

        state.selectedRequestID = requests[2].id

        XCTAssertTrue(state.openTabs.contains(requests[1].id), "kalıcı sekme açık kalmalı")
    }

    func testClosingSelectedTabSelectsNeighbour() {
        let requests = threeRequests()
        requests.forEach { state.pinTab($0.id) }
        state.selectedRequestID = requests[1].id

        state.closeTab(requests[1].id)

        XCTAssertFalse(state.openTabs.contains(requests[1].id))
        XCTAssertNotNil(state.selectedRequestID)
        XCTAssertNotEqual(state.selectedRequestID, requests[1].id)
    }

    func testDeletingRequestRemovesItsTab() {
        let requests = threeRequests()
        requests.forEach { state.pinTab($0.id) }

        state.deleteRequest(requests[0].id)

        XCTAssertFalse(state.openTabs.contains(requests[0].id))
    }
}
