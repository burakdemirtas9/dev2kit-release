import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// İstek yaşam döngüsü: ekleme, çoğaltma, taşıma, silme ve seçim etkileri.
@MainActor
final class AppStateRequestTests: XCTestCase {
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

    // MARK: - Kirlilik
    //
    // Bu iki test bir refactor'ün uygulamayı açılışta çökerttiği yolu koruyor:
    // `isDirty` isteğe yazma erişimi alırken aynı anda workspace'i okuyordu
    // (Swift exclusivity). Core'daki 488 test bunu yakalayamazdı.

    func testIsDirtyIsFalseWithoutBaseline() {
        let request = harness.addRequest(named: "yeni")
        XCTAssertFalse(state.isDirty(request.id))
        XCTAssertTrue(state.dirtyRequestIDs.isEmpty)
    }

    func testIsDirtyTurnsTrueAfterEditingSentRequest() {
        var request = harness.addRequest(named: "gönderilmiş")
        state.recordBaseline(request)
        XCTAssertFalse(state.isDirty(request.id), "gönderildiği haldeyken farklı sayılmamalı")

        request.url = "https://baska.example.com"
        state.selectedRequest?.wrappedValue = request

        XCTAssertTrue(state.isDirty(request.id))
        XCTAssertEqual(state.dirtyRequestIDs, [request.id])
    }

    func testRevertToLastSentRestoresFieldsButKeepsName() {
        var request = harness.addRequest(named: "ad", url: "https://ilk.example.com")
        state.recordBaseline(request)
        request.url = "https://degisti.example.com"
        request.name = "yeni ad"
        state.selectedRequest?.wrappedValue = request

        state.revertToLastSent(request.id)

        let reverted = state.request(withID: request.id)
        XCTAssertEqual(reverted?.url, "https://ilk.example.com")
        XCTAssertEqual(reverted?.name, "yeni ad", "ad kullanıcının; geri alma ona dokunmamalı")
        XCTAssertFalse(state.isDirty(request.id))
    }

    // MARK: - Ekleme ve çoğaltma

    func testAddRequestSelectsAndPinsIt() {
        let request = harness.addRequest(named: "ilk")
        XCTAssertEqual(state.selectedRequestID, request.id)
        XCTAssertTrue(state.openTabs.contains(request.id))
        XCTAssertNotEqual(state.previewTabID, request.id, "yeni istek kalıcı sekme olmalı")
    }

    func testDuplicateInsertsCopyRightAfterOriginal() {
        let original = harness.addRequest(named: "kaynak")
        state.duplicateRequest(original.id)

        let names = harness.firstCollection.requests.map(\.name)
        XCTAssertEqual(names.suffix(2), ["kaynak", "kaynak kopya"])
        XCTAssertNotEqual(state.selectedRequestID, original.id, "kopya seçili olmalı")
    }

    func testDuplicateTwiceNumbersTheSecondCopy() {
        let original = harness.addRequest(named: "kaynak")
        state.duplicateRequest(original.id)
        state.duplicateRequest(original.id)
        let names = harness.firstCollection.requests.map(\.name)
        XCTAssertTrue(names.contains("kaynak kopya"))
        XCTAssertTrue(names.contains("kaynak kopya 2"), "ikinci kopya numaralanmalı: \(names)")
    }

    // MARK: - Silme

    func testDeleteRemovesRequestClosesTabAndClearsSelection() {
        let request = harness.addRequest(named: "silinecek")
        state.deleteRequest(request.id)

        XCTAssertNil(state.request(withID: request.id))
        XCTAssertFalse(state.openTabs.contains(request.id))
        XCTAssertNil(state.selectedRequestID)
    }

    func testDeleteRequestsRemovesAllSelected() {
        let a = harness.addRequest(named: "a")
        let b = harness.addRequest(named: "b")
        let c = harness.addRequest(named: "c")

        state.deleteRequests([a.id, c.id])

        let remaining = harness.firstCollection.requests.map(\.name)
        XCTAssertFalse(remaining.contains("a"))
        XCTAssertFalse(remaining.contains("c"))
        XCTAssertTrue(remaining.contains("b"))
        XCTAssertNotNil(state.request(withID: b.id))
    }

    // MARK: - Taşıma

    func testMoveRequestsToAnotherCollectionKeepsOrderAndSelectsThem() {
        let a = harness.addRequest(named: "a")
        let b = harness.addRequest(named: "b")
        state.addCollection()
        let target = state.workspace.collections.last!

        state.moveRequests([a.id, b.id], toCollection: target.id)

        let moved = state.workspace.collections.last!.requests.map(\.name)
        XCTAssertEqual(moved, ["a", "b"], "kaynak sıra korunmalı")
        XCTAssertEqual(state.selectedRequestIDs, [a.id, b.id])
    }

    func testMoveResolvesNameConflictInTarget() {
        let a = harness.addRequest(named: "çakışan")
        state.addCollection()
        let target = state.workspace.collections.last!
        state.addRequest(to: target.id)
        var existing = state.request(withID: state.selectedRequestID!)!
        existing.name = "çakışan"
        state.selectedRequest?.wrappedValue = existing

        state.moveRequests([a.id], toCollection: target.id)

        let names = state.workspace.collections.last!.requests.map(\.name)
        XCTAssertEqual(names.filter { $0 == "çakışan" }.count, 1)
        XCTAssertTrue(names.contains("çakışan taşınan"), "çakışma çözülmeliydi: \(names)")
    }
}
