import XCTest
@testable import BoltDockCore

final class VariableResolverTests: XCTestCase {
    private func makeResolver(
        variables: [String: String] = [:],
        secrets: [String: String] = [:]
    ) -> VariableResolver {
        let environment = EnvironmentModel(
            name: "test",
            variables: variables.map { KeyValueEntry(key: $0.key, value: $0.value) }
        )
        return VariableResolver(environment: environment, secretStore: InMemorySecretStore(initial: secrets))
    }

    func testPlainTextPassesThrough() throws {
        XCTAssertEqual(try makeResolver().resolve("https://api.example.com"), "https://api.example.com")
    }

    func testResolvesVariable() throws {
        let resolver = makeResolver(variables: ["baseUrl": "https://api.example.com"])
        XCTAssertEqual(try resolver.resolve("{{baseUrl}}/users"), "https://api.example.com/users")
    }

    func testResolvesSecret() throws {
        let resolver = makeResolver(secrets: ["token": "s3cr3t"])
        XCTAssertEqual(try resolver.resolve("Bearer {{secret:token}}"), "Bearer s3cr3t")
    }

    func testResolvesNestedVariable() throws {
        let resolver = makeResolver(variables: [
            "baseUrl": "https://{{host}}",
            "host": "api.example.com",
        ])
        XCTAssertEqual(try resolver.resolve("{{baseUrl}}/v1"), "https://api.example.com/v1")
    }

    func testUnknownVariableThrows() {
        XCTAssertThrowsError(try makeResolver().resolve("{{yok}}")) { error in
            XCTAssertEqual(error as? VariableResolver.ResolveError, .unknownVariable("yok"))
        }
    }

    func testSecretNameWithoutPrefixSuggestsCorrectSyntax() {
        let resolver = makeResolver(secrets: ["test12": "abc"])
        XCTAssertThrowsError(try resolver.resolve("{{test12}}")) { error in
            XCTAssertEqual(error as? VariableResolver.ResolveError, .variableIsSecret("test12"))
        }
    }

    func testUnknownSecretThrows() {
        XCTAssertThrowsError(try makeResolver().resolve("{{secret:yok}}")) { error in
            XCTAssertEqual(error as? VariableResolver.ResolveError, .unknownSecret("yok"))
        }
    }

    func testCyclicReferenceThrows() {
        let resolver = makeResolver(variables: ["a": "{{b}}", "b": "{{a}}"])
        XCTAssertThrowsError(try resolver.resolve("{{a}}"))
    }

    func testWhitespaceInsideBracesTolerated() throws {
        let resolver = makeResolver(variables: ["x": "1"])
        XCTAssertEqual(try resolver.resolve("{{ x }}"), "1")
    }

    func testDisabledVariableIgnored() {
        let environment = EnvironmentModel(name: "test", variables: [
            KeyValueEntry(key: "x", value: "1", enabled: false)
        ])
        let resolver = VariableResolver(environment: environment, secretStore: InMemorySecretStore())
        XCTAssertThrowsError(try resolver.resolve("{{x}}"))
    }
}
