import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kenar çubuğu özeti uygulamada (2026-11-01): workspace değişince aynı
/// turun sonunda bir kez yenilenir; yalnızca gösterilen şey değişince farklı.
@MainActor
final class SidebarSnapshotFlowTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }

    override func setUp() async throws { harness = AppStateHarness() }
    override func tearDown() async throws { harness.tearDown(); harness = nil }

    /// Bekleyen yenilemenin çalışması için bir run loop turu.
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private var shownNames: [String] {
        state.sidebarCollections.flatMap(\.requests).map(\.name)
    }

    func testNewAndRenamedRequestsAppear() {
        let request = harness.addRequest(named: "Kullanıcılar")
        settle()
        XCTAssertTrue(shownNames.contains("Kullanıcılar"))
        state.withRequest(request.id) { $0.name = "Kullanıcı listesi" }
        settle()
        XCTAssertTrue(shownNames.contains("Kullanıcı listesi"))
        XCTAssertFalse(shownNames.contains("Kullanıcılar"))
    }

    func testTypingInHeadersBodyOrURLKeepsTheSnapshot() {
        let request = harness.addRequest(named: "R")
        settle()
        let before = state.sidebarSnapshot
        state.withRequest(request.id) {
            $0.headers = [KeyValueEntry(key: "Authorization", value: "Bearer x")]
            $0.body = .raw(content: "{}", contentType: "application/json")
            $0.url = "https://a.test/users"
        }
        settle()
        XCTAssertEqual(state.sidebarSnapshot, before, "kenar çubuğu yeniden çizilmez")
    }

    func testManyChangesInOneTurnRefreshOnce() {
        let request = harness.addRequest(named: "R")
        settle()
        for index in 0..<50 { state.withRequest(request.id) { $0.name = "R\(index)" } }
        XCTAssertTrue(state.sidebarSnapshotScheduled, "yenileme bekliyor (her değişiklikte değil)")
        settle()
        XCTAssertFalse(state.sidebarSnapshotScheduled)
        XCTAssertTrue(shownNames.contains("R49"))
    }

    func testSearchStillMatchesURLs() {
        let request = harness.addRequest(named: "Sipariş", url: "https://shop.test/orders/{{id}}")
        harness.addRequest(named: "Başka", url: "https://other.test")
        settle()
        state.searchQuery = "orders"
        XCTAssertEqual(shownNames, ["Sipariş"])
        XCTAssertEqual(state.sidebarCollections.flatMap(\.requests).map(\.id), [request.id])
        state.searchQuery = ""
        XCTAssertTrue(shownNames.contains("Başka"))
    }

    func testDirtyMarkFollowsEdits() {
        let request = harness.addRequest(named: "R", url: "https://a.test")
        state.workspace.sentBaselines[request.id.uuidString] = state.request(withID: request.id)
        settle()
        XCTAssertFalse(state.sidebarSnapshot.dirty.contains(request.id))
        state.withRequest(request.id) { $0.url = "https://b.test" }
        settle()
        XCTAssertTrue(state.sidebarSnapshot.dirty.contains(request.id), "değişti işareti görünür")
        XCTAssertEqual(state.sidebarSnapshot.dirty, state.dirtyRequestIDs, "eski hesapla aynı")
    }
}
