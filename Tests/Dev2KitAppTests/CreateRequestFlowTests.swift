import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Boş durumdaki "yeni bir istek oluştur": varsayılan hedef Koleksiyonsuz,
/// tamamlanınca istek orada ve açık; iptalde kayıt yok.
@MainActor
final class CreateRequestFlowTests: XCTestCase {
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

    func testCreatesUnderUngroupedAndOpensIt() throws {
        let id = try XCTUnwrap(state.createRequest(name: "  Kullanıcılar  ", method: .post, destination: .ungrouped))
        let ungrouped = try XCTUnwrap(state.workspace.collections.first(where: \.isUngrouped))
        XCTAssertEqual(ungrouped.requests.map(\.id), [id])
        XCTAssertEqual(ungrouped.requests.first?.name, "Kullanıcılar")
        XCTAssertEqual(ungrouped.requests.first?.method, .post)
        XCTAssertEqual(state.selectedRequestID, id, "düzenlemek için açılmalı")
        XCTAssertTrue(state.openTabs.contains(id))
    }

    func testEmptyNameFallsBackToDefault() throws {
        let id = try XCTUnwrap(state.createRequest(name: " ", method: .get, destination: .ungrouped))
        XCTAssertEqual(state.request(withID: id)?.name, RequestModel().name)
    }

    func testClearsSearchSoTheNewRequestIsVisible() {
        state.searchQuery = "başka"
        state.createRequest(name: "x", method: .get, destination: .ungrouped)
        XCTAssertEqual(state.searchQuery, "")
    }

    func testUnresolvableDestinationWritesNothing() {
        let before = state.workspace.collections
        XCTAssertNil(state.createRequest(name: "x", method: .get, destination: .new(name: "  ")))
        XCTAssertEqual(state.workspace.collections, before)
    }

    func testCanTargetExistingCollection() throws {
        let collection = CollectionModel(name: "Ödeme")
        state.workspace.collections.append(collection)
        let id = try XCTUnwrap(state.createRequest(name: "x", method: .get, destination: .existing(collection.id)))
        XCTAssertEqual(state.workspace.collections.first { $0.id == collection.id }?.requests.map(\.id), [id])
    }
}
