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

    // MARK: - Baloncukta düzenleme (2026-10-29)

    /// Değer, çözümün kullandığı satıra yazılır (son açık satır); kapalı ve
    /// öteki satırlar değişmez, gönderim yeni değeri görür.
    func testUpdateWritesTheRowThatResolves() throws {
        let first = KeyValueEntry(key: "host", value: "a")
        let used = KeyValueEntry(key: "host", value: "b")
        let off = KeyValueEntry(key: "host", value: "c", enabled: false)
        let other = KeyValueEntry(key: "other", value: "x")
        var env = EnvironmentModel(name: "Dev", variables: [first, used, off, other])

        try VariableDefinition.update(key: "host", value: "https://new.test", in: &env)

        XCTAssertEqual(env.variables.map(\.value), ["a", "https://new.test", "c", "x"])
        XCTAssertEqual(env.variables.map(\.id), [first.id, used.id, off.id, other.id], "satır eklenmez, sıra aynı")
        XCTAssertEqual(TemplateVariables.preview(for: "host", environment: env, tokenVariables: [], secretNames: []),
                       .environment(environmentName: "Dev", value: "https://new.test"))
        XCTAssertEqual(try VariableResolver(environment: env, secretStore: InMemorySecretStore()).resolve("{{host}}/x"), "https://new.test/x")
    }

    func testUpdateKeepsValueAsTyped() throws {
        var env = EnvironmentModel(variables: [KeyValueEntry(key: "name", value: "old")])
        try VariableDefinition.update(key: "name", value: "", in: &env)
        XCTAssertEqual(env.variables.first?.value, "", "boş değer de kaydedilir")
        try VariableDefinition.update(key: "name", value: "  Ali \"Veli\" {{x}} ", in: &env)
        XCTAssertEqual(env.variables.first?.value, "  Ali \"Veli\" {{x}} ", "kırpılmaz, kaçışlanmaz")
    }

    /// Açık satır yoksa (silinmiş ya da kapatılmış) yeni satır açılmaz,
    /// kapalı satır da açılmaz.
    func testUpdateRefusesMissingOrDisabledVariable() {
        var env = EnvironmentModel(variables: [KeyValueEntry(key: "host", value: "old", enabled: false)])
        let before = env
        XCTAssertThrowsError(try VariableDefinition.update(key: "host", value: "new", in: &env)) {
            XCTAssertEqual($0 as? VariableDefinition.SaveError, .missing)
        }
        XCTAssertThrowsError(try VariableDefinition.update(key: "absent", value: "new", in: &env)) {
            XCTAssertEqual($0 as? VariableDefinition.SaveError, .missing)
        }
        XCTAssertEqual(env, before)
    }
}
