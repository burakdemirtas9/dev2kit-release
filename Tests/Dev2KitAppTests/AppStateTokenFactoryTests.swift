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

    func testRegularRequestIsCopiedIntoFactory() throws {
        let original = harness.addRequest(named: "login")
        state.copyToTokenFactory([original.id])

        let copy = try XCTUnwrap(factory?.requests.first)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "login")
        XCTAssertEqual(copy.url, original.url)
        XCTAssertEqual(copy.tokenOutput?.variableName, "token")
        // Asıl istek yerinde kalır, Token Factory'ye dönüşmez.
        XCTAssertFalse(state.isTokenFactoryRequest(original.id))
        XCTAssertNotNil(state.request(withID: original.id))
        // Kopya Token sekmesinde açılır: yanıt alanı oradan ayarlanır.
        XCTAssertEqual(state.selectedRequestID, copy.id)
        XCTAssertEqual(state.editorTab, .token)
    }

    func testCopiesGetTheirOwnVariableAndName() throws {
        state.addTokenFactoryRequest()
        let first = harness.addRequest(named: "Token İsteği")
        let second = harness.addRequest(named: "login")
        state.copyToTokenFactory([first.id, second.id])

        XCTAssertEqual(factory?.requests.map(\.name), ["Token İsteği", "Token İsteği kopya", "login"])
        XCTAssertEqual(factory?.requests.compactMap(\.tokenOutput?.variableName), ["token", "token2", "token3"])
        XCTAssertTrue(TokenFactory.problems(in: factory?.requests ?? [], environment: nil).isEmpty)
    }

    func testCopyingFactoryRequestsIsIgnored() throws {
        state.addTokenFactoryRequest()
        let factoryRequest = try XCTUnwrap(factory?.requests.first)
        state.copyToTokenFactory([factoryRequest.id])
        XCTAssertEqual(factory?.requests.count, 1)
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

/// Bellekteki token, token isteğinin gönderilecek hali değişince düşer.
@MainActor
final class AppStateTokenCacheTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }
    private let token = TokenFactory.IssuedToken(value: "sahte-token", expiresAt: nil)

    override func setUp() {
        super.setUp()
        harness = AppStateHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
        super.tearDown()
    }

    /// `{{customerNo}}` kullanan bir token isteği, aktif environment ve
    /// bellekte o hal için alınmış bir token.
    private func prepare() throws -> UUID {
        let environmentID = state.addEnvironment()
        state.workspace.activeEnvironmentID = environmentID
        state.environmentBinding(environmentID)?.wrappedValue.variables = [
            KeyValueEntry(key: "customerNo", value: "111"),
            KeyValueEntry(key: "pageSize", value: "20"),
        ]
        state.addTokenFactoryRequest()
        var request = try XCTUnwrap(state.selectedRequest?.wrappedValue)
        request.url = "https://auth/token"
        request.body = .formURLEncoded(fields: [KeyValueEntry(key: "username", value: "{{customerNo}}")])
        state.selectedRequest?.wrappedValue = request
        try cacheToken()
        return environmentID
    }

    private func cacheToken() throws {
        let environment = state.activeEnvironment
        let source = try XCTUnwrap(state.tokenSources(for: environment).first)
        let key = state.tokenKey(source, environment: environment)
        state.tokenCache[key] = token
        state.tokenStates[key] = .valid(expiresAt: nil)
    }

    private func setVariable(_ name: String, to value: String, in environmentID: UUID) {
        guard var environment = state.environmentBinding(environmentID)?.wrappedValue,
              let index = environment.variables.firstIndex(where: { $0.key == name }) else {
            return XCTFail("\(name) yok")
        }
        environment.variables[index].value = value
        state.environmentBinding(environmentID)?.wrappedValue = environment
    }

    func testEditingTheBodyDropsTheToken() throws {
        _ = try prepare()
        var request = try XCTUnwrap(state.selectedRequest?.wrappedValue)
        request.body = .formURLEncoded(fields: [KeyValueEntry(key: "username", value: "sabit")])
        state.selectedRequest?.wrappedValue = request
        XCTAssertTrue(state.tokenCache.isEmpty, "eski gövdenin token'ı bellekte kalmamalı")
        XCTAssertTrue(state.tokenStates.isEmpty, "panelde durum noktası sönmeli")
    }

    func testChangingAUsedVariableDropsTheToken() throws {
        let environmentID = try prepare()
        setVariable("customerNo", to: "222", in: environmentID)
        XCTAssertTrue(state.tokenCache.isEmpty, "111'in token'ı 222 için kullanılmamalı")
    }

    func testRenamingOrUnrelatedChangesKeepTheToken() throws {
        let environmentID = try prepare()
        var request = try XCTUnwrap(state.selectedRequest?.wrappedValue)
        request.name = "Müşteri girişi"
        state.selectedRequest?.wrappedValue = request
        setVariable("pageSize", to: "50", in: environmentID)
        XCTAssertEqual(state.tokenCache.count, 1)
    }

    func testDeletingTheTokenRequestDropsTheToken() throws {
        _ = try prepare()
        let id = try XCTUnwrap(state.selectedRequestID)
        state.deleteRequest(id)
        XCTAssertTrue(state.tokenCache.isEmpty)
    }

    func testManualResponseForAnOutdatedRequestIsNotStored() throws {
        // Yanıt beklenirken istek düzenlendi: gelen token eski halin token'ı.
        _ = try prepare()
        state.tokenCache = [:]
        state.tokenStates = [:]
        let sent = try XCTUnwrap(state.selectedRequest?.wrappedValue)
        var edited = sent
        edited.url = "https://baska/token"
        state.selectedRequest?.wrappedValue = edited

        let response = ResponseData(
            statusCode: 200,
            headers: [],
            body: Data(#"{"access_token":"eski-hal"}"#.utf8),
            duration: 0,
            finalURL: nil
        )
        state.absorbTokenResponse(sent, response: response, environment: state.activeEnvironment)
        XCTAssertTrue(state.tokenCache.isEmpty)

        state.absorbTokenResponse(edited, response: response, environment: state.activeEnvironment)
        XCTAssertEqual(state.tokenCache.values.first?.value, "eski-hal")
    }
}
