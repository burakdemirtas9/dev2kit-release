import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Boş durumdaki "yeni bir istek oluştur": tek tıkla varsayılan istek
/// Koleksiyonsuz'a eklenir, açılır, kenar çubuğunda görünür ve adres alanı
/// odak alır; açık istekler ve düzenlemeler korunur.
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

    func testOneClickCreatesDefaultRequestUnderUngrouped() throws {
        let id = try XCTUnwrap(state.createUngroupedRequest())
        let ungrouped = try XCTUnwrap(state.workspace.collections.first(where: \.isUngrouped))
        let request = try XCTUnwrap(ungrouped.requests.first { $0.id == id })
        XCTAssertEqual(request.name, RequestModel().name)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url, "")
        XCTAssertEqual(state.selectedRequestID, id)
        XCTAssertEqual(state.sidebarRevealID, id, "kenar çubuğu isteğe kaymalı")
        XCTAssertTrue(state.takeAddressFocus(), "adres alanı odak almalı")
        XCTAssertFalse(state.takeAddressFocus(), "bir kez okunur")
    }

    func testCollapsedUngroupedIsExpanded() throws {
        let ungroupedID = state.workspace.ensureUngroupedCollection()
        state.workspace.collections[0].requests.append(RequestModel(name: "eski"))
        state.collapsedCollectionIDs.insert(ungroupedID)
        try XCTUnwrap(state.createUngroupedRequest())
        XCTAssertFalse(state.collapsedCollectionIDs.contains(ungroupedID))
    }

    func testOpenRequestsAndEditsArePreserved() throws {
        let collection = CollectionModel(name: "Ödeme", requests: [RequestModel(name: "a", url: "https://a.test/edited")])
        state.workspace.collections.append(collection)
        let existing = collection.requests[0].id
        state.showRequest(existing)
        let before = state.request(withID: existing)

        let id = try XCTUnwrap(state.createUngroupedRequest())

        XCTAssertTrue(state.openTabs.contains(existing), "açık sekme kapanmamalı")
        XCTAssertTrue(state.openTabs.contains(id))
        XCTAssertEqual(state.request(withID: existing), before, "düzenleme korunmalı")
    }
}
