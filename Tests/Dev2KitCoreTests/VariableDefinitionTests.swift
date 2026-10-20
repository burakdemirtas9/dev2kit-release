import XCTest
@testable import Dev2KitCore

final class VariableDefinitionTests: XCTestCase {
    func testKeyStripsDelimitersAndSpaces() {
        XCTAssertEqual(VariableDefinition.key(from: "{{ test-finance-bff-service }}"), "test-finance-bff-service")
        XCTAssertEqual(VariableDefinition.key(from: "baseUrl"), "baseUrl")
    }

    func testKeyRejectsSecretsAndEmpty() {
        XCTAssertNil(VariableDefinition.key(from: "{{secret:token}}"))
        XCTAssertNil(VariableDefinition.key(from: "{{  }}"))
        XCTAssertNil(VariableDefinition.key(from: "{{a{b}}"))
    }

    private let a = EnvironmentModel(name: "A")
    private let b = EnvironmentModel(name: "B")

    func testTargetIsActiveEnvironment() {
        XCTAssertEqual(VariableDefinition.target(activeID: b.id, environments: [a, b]), .environment(b.id))
    }

    func testSingleEnvironmentIsUnambiguous() {
        XCTAssertEqual(VariableDefinition.target(activeID: nil, environments: [a]), .environment(a.id))
    }

    func testSeveralWithoutActiveMustBeChosen() {
        XCTAssertEqual(VariableDefinition.target(activeID: nil, environments: [a, b]), .choose)
        // Silinmiş bir etkin kimlik de belirsizdir.
        XCTAssertEqual(VariableDefinition.target(activeID: UUID(), environments: [a, b]), .choose)
    }

    func testNoEnvironmentCreatesOne() {
        XCTAssertEqual(VariableDefinition.target(activeID: nil, environments: []), .createNew)
    }

    func testPlanFindsTheRowResolutionUses() {
        let first = KeyValueEntry(key: "host", value: "1")
        let second = KeyValueEntry(key: "host", value: "2")
        let env = EnvironmentModel(variables: [first, second])
        XCTAssertEqual(VariableDefinition.plan(for: "host", in: env), .existing(entryID: second.id, isDisabled: false))
    }

    func testPlanPrefersEnabledRowAndReportsDisabled() {
        let on = KeyValueEntry(key: "host", value: "1")
        let off = KeyValueEntry(key: "host", value: "2", enabled: false)
        XCTAssertEqual(VariableDefinition.plan(for: "host", in: EnvironmentModel(variables: [on, off])),
                       .existing(entryID: on.id, isDisabled: false))
        XCTAssertEqual(VariableDefinition.plan(for: "host", in: EnvironmentModel(variables: [off])),
                       .existing(entryID: off.id, isDisabled: true))
    }

    func testPlanNewWhenMissing() {
        XCTAssertEqual(VariableDefinition.plan(for: "host", in: EnvironmentModel()), .new)
    }

    func testAddAppendsEnabledRowAndResolves() throws {
        let keep = KeyValueEntry(key: "other", value: "x")
        var env = EnvironmentModel(variables: [keep])
        try VariableDefinition.add(key: " host ", value: "https://api.test", to: &env)
        XCTAssertEqual(env.variables.first, keep, "mevcut değerler korunur")
        XCTAssertEqual(env.variables.last?.key, "host")
        let preview = TemplateVariables.preview(for: "host", environment: env, tokenVariables: [], secretNames: [])
        XCTAssertEqual(preview, .environment(environmentName: env.name, value: "https://api.test"))
    }

    func testAddRefusesDuplicateAndEmpty() {
        var env = EnvironmentModel(variables: [KeyValueEntry(key: "host", value: "old")])
        XCTAssertThrowsError(try VariableDefinition.add(key: "host", value: "new", to: &env)) {
            XCTAssertEqual($0 as? VariableDefinition.SaveError, .duplicate)
        }
        XCTAssertEqual(env.variables.first?.value, "old")
        XCTAssertThrowsError(try VariableDefinition.add(key: "  ", value: "v", to: &env)) {
            XCTAssertEqual($0 as? VariableDefinition.SaveError, .emptyKey)
        }
    }
}
