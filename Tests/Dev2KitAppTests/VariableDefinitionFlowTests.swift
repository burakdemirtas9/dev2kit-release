import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Tanımsız değişkene tıklayıp değer verme: açarken hiçbir şey yazılmaz,
/// kaydedince açık istekte hemen çözülür, mevcut değerler korunur.
@MainActor
final class VariableDefinitionFlowTests: XCTestCase {
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

    private func environment(_ name: String, _ variables: [KeyValueEntry] = []) -> UUID {
        let env = EnvironmentModel(name: name, variables: variables)
        state.workspace.environments.append(env)
        return env.id
    }

    func testOpeningWritesNothingAndTargetsActiveEnvironment() {
        let id = environment("TestEnv", [KeyValueEntry(key: "other", value: "x")])
        state.workspace.activeEnvironmentID = id
        let before = state.workspace.environments
        let request = state.environmentsRequest

        state.defineVariable("{{ finance-bff-service }}")

        XCTAssertEqual(state.environmentsRequest, request + 1)
        XCTAssertEqual(state.workspace.environments, before, "kaydedilmeden yazılmamalı")
        let taken = state.takeVariableDefinitionRequest()
        XCTAssertEqual(taken, .init(key: "finance-bff-service", target: .environment(id)))
        XCTAssertNil(state.takeVariableDefinitionRequest(), "bir kez okunur")
    }

    func testSecretVariablesAreNotSentToEnvironments() {
        state.defineVariable("{{secret:token}}")
        XCTAssertNil(state.takeVariableDefinitionRequest())
    }

    func testSavingResolvesImmediatelyAndKeepsExistingValues() throws {
        let keep = KeyValueEntry(key: "other", value: "x")
        let id = environment("TestEnv", [keep])
        state.workspace.activeEnvironmentID = id
        XCTAssertFalse(state.variablePreview(for: "host").isDefined)

        try state.saveVariable(key: "host", value: "https://api.test", environmentID: id)

        XCTAssertEqual(state.variablePreview(for: "host"), .environment(environmentName: "TestEnv", value: "https://api.test"))
        XCTAssertEqual(state.activeEnvironment?.variables.first, keep)
    }

    func testChosenEnvironmentBecomesActiveWhenNoneIsActive() throws {
        _ = environment("A")
        let b = environment("B")
        state.workspace.activeEnvironmentID = nil

        try state.saveVariable(key: "host", value: "v", environmentID: b)

        XCTAssertEqual(state.workspace.activeEnvironmentID, b)
        XCTAssertTrue(state.variablePreview(for: "host").isDefined)
    }

    func testActiveEnvironmentIsNotSwitched() throws {
        let a = environment("A")
        let b = environment("B")
        state.workspace.activeEnvironmentID = a
        try state.saveVariable(key: "host", value: "v", environmentID: b)
        XCTAssertEqual(state.workspace.activeEnvironmentID, a)
    }

    func testNoEnvironmentCreatesAndActivatesOne() throws {
        state.workspace.environments = []
        state.workspace.activeEnvironmentID = nil
        try state.saveVariable(key: "host", value: "v", environmentID: nil)
        XCTAssertEqual(state.workspace.environments.count, 1)
        XCTAssertTrue(state.variablePreview(for: "host").isDefined)
    }

    func testDuplicateDoesNotOverwriteOrLeaveEmptyEnvironment() {
        let id = environment("A", [KeyValueEntry(key: "host", value: "old")])
        XCTAssertThrowsError(try state.saveVariable(key: "host", value: "new", environmentID: id))
        XCTAssertEqual(state.workspace.environments.first { $0.id == id }?.variables.first?.value, "old")

        let count = state.workspace.environments.count
        XCTAssertThrowsError(try state.saveVariable(key: " ", value: "v", environmentID: nil))
        XCTAssertEqual(state.workspace.environments.count, count, "boş adla environment oluşmamalı")
    }

    // MARK: - Seçiciden doğrudan düzenleme (2026-10-20)

    /// Seçicideki düzenle düğmesi pencereyi o environment seçili açar;
    /// istek bir kez okunur.
    func testEditButtonOpensTheWindowOnThatEnvironment() {
        let first = state.addEnvironment()
        let second = state.addEnvironment()
        let before = state.environmentsRequest
        state.showEnvironments(focus: second)
        XCTAssertEqual(state.environmentsRequest, before + 1)
        XCTAssertEqual(state.takeEnvironmentsFocusID(), second)
        XCTAssertNil(state.takeEnvironmentsFocusID(), "ikinci okuma boş")
        XCTAssertEqual(state.workspace.activeEnvironmentID, first, "düzenlemek aktif environment'ı değiştirmez")
    }

    func testFocusOnADeletedEnvironmentIsIgnored() {
        let id = state.addEnvironment()
        state.showEnvironments(focus: id)
        state.deleteEnvironment(id)
        XCTAssertNil(state.takeEnvironmentsFocusID())
    }

    /// Environment yokken "Environment Ekle": yenisi oluşur, aktif olur ve
    /// pencere onu seçili açar.
    func testAddingFromThePickerCreatesActivatesAndFocuses() {
        XCTAssertTrue(state.workspace.environments.isEmpty)
        let id = state.addEnvironment()
        state.showEnvironments(focus: id)
        XCTAssertEqual(state.workspace.activeEnvironmentID, id)
        XCTAssertEqual(state.takeEnvironmentsFocusID(), id)
    }

    /// Environment'lar varken de "Yeni Environment…" (2026-10-31): yenisi
    /// oluşur, adı tekrar etmez, etkin olan değişmez, pencere onu seçili ve
    /// adı düzenlenmeye hazır açar.
    func testNewEnvironmentFromThePickerWhenOthersExist() {
        let first = state.addEnvironment()
        let id = state.addEnvironment()
        state.showEnvironments(focus: id, editName: true)

        XCTAssertEqual(state.workspace.activeEnvironmentID, first, "etkin environment değişmez")
        XCTAssertEqual(state.workspace.environments.map(\.name),
                       [L10n.t("environment.defaultName"), L10n.t("environment.defaultName") + " 2"])
        XCTAssertEqual(state.takeEnvironmentsFocusID(), id)
        XCTAssertEqual(state.takeEnvironmentsNameEditID(), id)
        XCTAssertNil(state.takeEnvironmentsNameEditID(), "bir kez okunur")

        // Düzenle düğmesi adı düzenletmez.
        state.showEnvironments(focus: first)
        XCTAssertNil(state.takeEnvironmentsNameEditID())
    }

    // MARK: - Baloncukta düzenleme (2026-10-29)

    /// Tanımlı environment değişkeninin baloncuğu: düzenle kaydeder, değer
    /// açık istekte hemen çözülür ve diske yazılır. Aynı adın başka
    /// environment'taki değeri değişmez.
    func testEditingFromTheBubbleWritesTheActiveEnvironment() throws {
        let active = environment("Dev", [KeyValueEntry(key: "host", value: "https://old.test")])
        let other = environment("Prod", [KeyValueEntry(key: "host", value: "https://prod.test")])
        state.workspace.activeEnvironmentID = active
        let card = VariablePreviewCard(name: "host", appState: state) {}
        let save = try XCTUnwrap(card.saveValue, "environment değişkeni düzenlenebilir")

        XCTAssertNil(save("https://new.test"))

        XCTAssertEqual(state.variablePreview(for: "host"), .environment(environmentName: "Dev", value: "https://new.test"))
        XCTAssertEqual(state.workspace.environments.first { $0.id == other }?.variables.first?.value, "https://prod.test")
        XCTAssertEqual(state.workspace.activeEnvironmentID, active)
        let saved = try harness.savedWorkspace()
        XCTAssertEqual(saved.environments.first { $0.id == active }?.variables.first?.value, "https://new.test")
    }

    /// Baloncuk açıkken environment silinirse: hata metni, hiçbir yere
    /// yazılmaz, yeni environment oluşmaz.
    func testEditingAfterTheEnvironmentIsDeletedWritesNothing() throws {
        let id = environment("Dev", [KeyValueEntry(key: "host", value: "old")])
        state.workspace.activeEnvironmentID = id
        let card = VariablePreviewCard(name: "host", appState: state) {}
        let save = try XCTUnwrap(card.saveValue)
        state.deleteEnvironment(id)
        let before = state.workspace.environments

        XCTAssertEqual(save("new"), L10n.t("variable.edit.missing"))
        XCTAssertEqual(state.workspace.environments, before)
    }

    /// Baloncuk açıkken etkin environment değişirse değer, açılırken
    /// gösterilen environment'a yazılır.
    func testEditingTargetsTheEnvironmentShownInTheBubble() throws {
        let dev = environment("Dev", [KeyValueEntry(key: "host", value: "dev")])
        let prod = environment("Prod", [KeyValueEntry(key: "host", value: "prod")])
        state.workspace.activeEnvironmentID = dev
        let save = try XCTUnwrap(VariablePreviewCard(name: "host", appState: state) {}.saveValue)
        state.workspace.activeEnvironmentID = prod

        XCTAssertNil(save("dev2"))

        XCTAssertEqual(state.workspace.environments.first { $0.id == dev }?.variables.first?.value, "dev2")
        XCTAssertEqual(state.workspace.environments.first { $0.id == prod }?.variables.first?.value, "prod")
    }

    /// "Environment'ta Aç": baloncuk kapanır, pencere değişkenin satırında açılır.
    func testOpenInEnvironmentsGoesToTheRow() throws {
        let id = environment("Dev", [KeyValueEntry(key: "host", value: "v")])
        state.workspace.activeEnvironmentID = id
        var closed = false
        let card = VariablePreviewCard(name: "host", appState: state) { closed = true }
        let request = state.environmentsRequest

        try XCTUnwrap(card.openInEnvironments)()

        XCTAssertTrue(closed)
        XCTAssertEqual(state.environmentsRequest, request + 1)
        XCTAssertEqual(state.takeVariableDefinitionRequest(), .init(key: "host", target: .environment(id)))
    }

    /// Token Factory değişkeni (environment'taki aynı adı ezse de) ve secret
    /// baloncukta düzenlenmez; tanımsız değişkende yalnızca "ekle" var.
    func testOnlyEnvironmentVariablesAreEditable() throws {
        let id = environment("Dev", [KeyValueEntry(key: "token", value: "env-value")])
        state.workspace.activeEnvironmentID = id
        state.addTokenFactoryRequest()
        XCTAssertEqual(state.variablePreview(for: "token"), .token(requestName: L10n.t("token.defaultName")))

        let token = VariablePreviewCard(name: "token", appState: state) {}
        XCTAssertNil(token.saveValue, "Token Factory değeri Token Factory'nin")

        let secret = VariablePreviewCard(name: "secret:apiKey", appState: state) {}
        XCTAssertNil(secret.saveValue)
        XCTAssertNil(secret.openInEnvironments, "secret environment'a yazılmaz")

        let undefined = VariablePreviewCard(name: "missing", appState: state) {}
        XCTAssertNil(undefined.saveValue)
        XCTAssertNotNil(undefined.openInEnvironments)
        XCTAssertEqual(state.workspace.environments.first { $0.id == id }?.variables.map(\.value), ["env-value"])
    }
}
