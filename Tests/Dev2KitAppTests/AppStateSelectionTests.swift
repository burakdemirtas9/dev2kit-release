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

    func testKeptTabSurvivesNextSelection() {
        let requests = threeRequests()
        state.selectedRequestID = requests[1].id
        state.keepTab(requests[1].id)

        state.selectedRequestID = requests[2].id

        XCTAssertTrue(state.openTabs.contains(requests[1].id), "kalıcı sekme açık kalmalı")
    }

    func testClosingSelectedTabSelectsNeighbour() {
        let requests = threeRequests()
        requests.forEach { state.keepTab($0.id) }
        state.selectedRequestID = requests[1].id

        state.closeTab(requests[1].id)

        XCTAssertFalse(state.openTabs.contains(requests[1].id))
        XCTAssertNotNil(state.selectedRequestID)
        XCTAssertNotEqual(state.selectedRequestID, requests[1].id)
    }

    func testDeletingRequestRemovesItsTab() {
        let requests = threeRequests()
        requests.forEach { state.keepTab($0.id) }

        state.deleteRequest(requests[0].id)

        XCTAssertFalse(state.openTabs.contains(requests[0].id))
    }

    // MARK: - Sabitleme (2026-10-31)

    /// Sabitler başta ve sabitlenme sırasıyla; yeniden açılışta aynı sırayla gelir.
    func testPinnedTabsComeFirstAndSurviveRelaunch() {
        let requests = threeRequests()
        requests.forEach { state.keepTab($0.id) }
        state.pinTab(requests[2].id)
        state.pinTab(requests[0].id)
        XCTAssertEqual(state.openTabs, [requests[2].id, requests[0].id, requests[1].id])

        state.waitForPendingWrites()
        let reopened = AppState(store: harness.store, secretStore: FileSecretStore())
        XCTAssertEqual(reopened.openTabs, [requests[2].id, requests[0].id, requests[1].id])
        XCTAssertTrue(reopened.isTabPinned(requests[2].id))
        XCTAssertTrue(reopened.isTabPinned(requests[0].id))
        XCTAssertFalse(reopened.isTabPinned(requests[1].id))
    }

    func testDeletedPinnedRequestIsNotRestored() {
        let requests = threeRequests()
        requests.forEach { state.keepTab($0.id) }
        state.pinTab(requests[1].id)
        state.deleteRequest(requests[1].id)
        XCTAssertFalse(state.isTabPinned(requests[1].id))

        state.waitForPendingWrites()
        let reopened = AppState(store: harness.store, secretStore: FileSecretStore())
        XCTAssertFalse(reopened.openTabs.contains(requests[1].id))
    }

    func testMenuTogglesPinOfTheSelectedTab() {
        let requests = threeRequests()
        requests.forEach { state.keepTab($0.id) }
        state.selectedRequestID = requests[1].id
        state.toggleSelectedTabPin()
        XCTAssertEqual(state.openTabs.first, requests[1].id)
        state.toggleSelectedTabPin()
        XCTAssertFalse(state.isTabPinned(requests[1].id))
    }

    /// "Diğerlerini Kapat" sabitleri korur; ⌘W sabiti de kapatır (kullanıcı kararı).
    func testCloseOthersSparesPinnedButCloseTabClosesPinned() {
        let requests = threeRequests()
        requests.forEach { state.keepTab($0.id) }
        state.pinTab(requests[0].id)
        state.closeOtherTabs(requests[2].id)
        XCTAssertEqual(state.openTabs, [requests[0].id, requests[2].id])
        state.closeTab(requests[0].id)
        XCTAssertEqual(state.openTabs, [requests[2].id])
    }
}
