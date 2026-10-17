import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Token Factory'nin uygulama tarafı: kap, ekleme, çoğaltma, taşıma
/// kısıtları ve açılışta eski token değişkenlerinin taşınması.
@MainActor
final class AppStateTokenFactoryTests: XCTestCase {
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

    private var factory: CollectionModel? { state.workspace.collections.first(where: \.isTokenFactory) }

    func testFirstRequestGetsDefaultNamesAndIsSelected() throws {
        state.addTokenFactoryRequest()
        let request = try XCTUnwrap(factory?.requests.first)
        XCTAssertEqual(request.tokenOutput?.variableName, "token")
        XCTAssertEqual(request.tokenOutput?.responseField, "access_token")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(state.selectedRequestID, request.id)
        XCTAssertTrue(state.isTokenFactoryRequest(request.id))
    }

    func testNextRequestsDoNotCollide() {
        state.addTokenFactoryRequest()
        state.addTokenFactoryRequest()
        XCTAssertEqual(factory?.requests.compactMap(\.tokenOutput?.variableName), ["token", "token2"])
        XCTAssertEqual(state.workspace.collections.filter(\.isTokenFactory).count, 1)
    }

    func testDuplicateInFactoryGetsItsOwnVariable() throws {
        state.addTokenFactoryRequest()
        let original = try XCTUnwrap(factory?.requests.first)
        state.duplicateRequest(original.id)
        XCTAssertEqual(factory?.requests.compactMap(\.tokenOutput?.variableName), ["token", "token2"])
        XCTAssertTrue(TokenFactory.problems(in: factory?.requests ?? [], environment: nil).isEmpty)
    }

    func testCommandNInFactoryAddsATokenRequest() {
        state.addTokenFactoryRequest()
        state.addRequestToCurrentCollection()
        XCTAssertEqual(factory?.requests.count, 2)
        XCTAssertEqual(factory?.requests.last?.tokenOutput?.variableName, "token2")
    }

    func testRequestsCannotBeMovedIntoOrOutOfFactory() throws {
        let regular = harness.addRequest(named: "api")
        state.addTokenFactoryRequest()
        let factoryRequest = try XCTUnwrap(factory?.requests.first)
        let factoryID = try XCTUnwrap(factory?.id)

        state.moveRequests([regular.id], toCollection: factoryID)
        XCTAssertFalse(state.isTokenFactoryRequest(regular.id))

        state.moveRequests([factoryRequest.id], toCollection: harness.firstCollection.id)
        XCTAssertTrue(state.isTokenFactoryRequest(factoryRequest.id))
    }

    func testFactoryCannotBeRenamedOrDeleted() throws {
        state.addTokenFactoryRequest()
        let id = try XCTUnwrap(factory?.id)
        state.renameCollection(id, to: "Başka")
        state.deleteCollection(id)
        XCTAssertEqual(factory?.name, CollectionModel.tokenFactoryName)
    }

    func testFactoryIsNotInTheCollectionList() {
        state.addTokenFactoryRequest()
        XCTAssertFalse(state.visibleCollections.contains { $0.collection.isTokenFactory })
    }

    func testFactoryVariablesAreSuggested() {
        state.addTokenFactoryRequest()
        XCTAssertTrue(state.templateSuggestions(matching: "tok").contains("token"))
    }

    func testOpenTokenRequestJumpsToItsTokenTab() throws {
        // "Token içeriğini kontrol et" önerisinin düğmesi: üreten isteği açar.
        state.addTokenFactoryRequest()
        let factoryRequest = try XCTUnwrap(factory?.requests.first)
        let api = harness.addRequest(named: "api")
        XCTAssertEqual(state.selectedRequestID, api.id)

        state.openTokenRequest(producing: "token")
        XCTAssertEqual(state.selectedRequestID, factoryRequest.id)
        XCTAssertEqual(state.editorTab, .token)
    }

    func testTokenSettingsArePersisted() throws {
        state.addTokenFactoryRequest()
        let saved = try harness.savedWorkspace()
        XCTAssertEqual(saved.tokenFactoryRequests.first?.tokenOutput?.variableName, "token")
    }
}

/// Açılışta taşıma: eski environment "token değişkenleri" Token Factory'ye.
@MainActor
final class AppStateTokenMigrationTests: XCTestCase {
    func testLegacyTokenVariablesMoveToFactoryOnLaunch() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dev2kit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv(AppPaths.directoryEnvironmentKey, directory.path, 1)
        defer {
            unsetenv(AppPaths.directoryEnvironmentKey)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let env = EnvironmentModel(name: "Dev", tokenVariables: [
            TokenVariable(name: "accessToken", tokenURL: "https://auth/token", clientID: "c", clientSecret: "{{secret:s}}"),
        ])
        try store.save(WorkspaceModel(collections: [CollectionModel(name: "API")], environments: [env]))

        let state = AppState(store: store, secretStore: FileSecretStore())
        state.waitForPendingWrites()

        XCTAssertEqual(state.workspace.tokenFactoryRequests.map(\.tokenOutput?.variableName), ["accessToken"])
        XCTAssertTrue(state.workspace.environments.allSatisfy { $0.tokenVariables.isEmpty })
        // Kalıcı: ikinci açılışta yeniden taşınmaz, kopya oluşmaz.
        let reopened = AppState(store: store, secretStore: FileSecretStore())
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.workspace.tokenFactoryRequests.count, 1)
    }
}
