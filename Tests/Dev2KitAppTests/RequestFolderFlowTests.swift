import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Klasörlerin uygulamadaki akışı: yerleştirme, yeniden adlandırma, kaldırma,
/// kalıcılık ve collection'lar arası taşıma.
@MainActor
final class RequestFolderFlowTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }
    private var collectionID: UUID { harness.firstCollection.id }

    override func setUp() async throws { harness = AppStateHarness() }
    override func tearDown() async throws { harness.tearDown(); harness = nil }

    private var layout: [String] {
        state.sidebarSnapshot.collections[0].requests.map { ($0.folder + [$0.name]).joined(separator: "/") }
    }

    func testPlaceRenameRemoveAndPersist() throws {
        let a = harness.addRequest(named: "a"), b = harness.addRequest(named: "b")
        state.placeRequests([a.id, b.id], in: collectionID, folder: ["Kullanıcı", "Yönetim"])
        state.refreshSidebarSnapshot()
        XCTAssertTrue(layout.contains("Kullanıcı/Yönetim/a") && layout.contains("Kullanıcı/Yönetim/b"), "\(layout)")
        XCTAssertFalse(state.isDirty(a.id), "klasör 'son gönderilenden farklı' saydırmaz")

        state.renameFolder(["Kullanıcı"], to: "Üye", in: collectionID)
        XCTAssertEqual(state.request(withID: a.id)?.folder, ["Üye", "Yönetim"])
        XCTAssertEqual(try harness.savedWorkspace().collections[0].requests.first { $0.id == a.id }?.folder, ["Üye", "Yönetim"], "diske yazılır")

        state.removeFolder(["Üye"], in: collectionID)
        XCTAssertEqual(state.request(withID: a.id)?.folder, ["Yönetim"])
        state.placeRequests([a.id], in: collectionID, folder: [])
        XCTAssertEqual(state.request(withID: a.id)?.folder, [])
    }

    /// Klasörde oluşturulan istek o klasörde durur ve katlı klasör açılır.
    func testNewRequestInFolderExpandsIt() throws {
        let a = harness.addRequest(named: "a")
        state.placeRequests([a.id], in: collectionID, folder: ["K"])
        let folderID = RequestFolders.rowID(collection: collectionID, path: ["K"])
        state.toggleFolderCollapsed(folderID)
        XCTAssertTrue(state.isFolderCollapsed(folderID))

        state.addRequest(to: collectionID, folder: ["K"])
        let created = try XCTUnwrap(state.selectedRequestID.flatMap(state.request(withID:)))
        XCTAssertEqual(created.folder, ["K"])
        XCTAssertFalse(state.isFolderCollapsed(folderID), "yeni istek görünür olmalı")
    }

    /// Başka collection'a taşınan istek hedefte köke gelir.
    func testMovingToAnotherCollectionDropsTheFolder() throws {
        let a = harness.addRequest(named: "a")
        state.placeRequests([a.id], in: collectionID, folder: ["K"])
        state.addCollection()
        let target = try XCTUnwrap(state.workspace.collections.last?.id)
        state.moveRequests([a.id], toCollection: target)
        XCTAssertEqual(state.request(withID: a.id)?.folder, [])
    }
}
