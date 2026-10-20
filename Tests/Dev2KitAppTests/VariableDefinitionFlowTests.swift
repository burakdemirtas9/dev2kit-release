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
}
