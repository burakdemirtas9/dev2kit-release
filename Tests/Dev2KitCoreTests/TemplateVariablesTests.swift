import XCTest
@testable import Dev2KitCore

/// Alandaki `{{değişken}}` vurgusu ve baloncuk önizlemesi (2026-10-19).
final class TemplateVariablesTests: XCTestCase {
    func testSegments() {
        XCTAssertEqual(TemplateVariables.segments(in: "https://{{ host }}/v1/{{id}}?q=1"), [
            .text("https://"),
            .variable(raw: "{{ host }}", name: "host"),
            .text("/v1/"),
            .variable(raw: "{{id}}", name: "id"),
            .text("?q=1"),
        ])
        XCTAssertEqual(TemplateVariables.segments(in: "düz"), [.text("düz")])
        XCTAssertEqual(TemplateVariables.segments(in: ""), [])
        XCTAssertEqual(TemplateVariables.segments(in: "{{yarım"), [.text("{{yarım")])
    }

    private let environment = EnvironmentModel(name: "Test", variables: [
        KeyValueEntry(key: "host", value: "ilk"),
        KeyValueEntry(key: "host", value: "son"),
        KeyValueEntry(key: "kapali", value: "x", enabled: false),
        KeyValueEntry(key: "token", value: "env-degeri"),
    ])

    private func preview(_ name: String, environment: EnvironmentModel?? = nil) -> TemplateVariables.Preview {
        TemplateVariables.preview(
            for: name,
            environment: environment ?? self.environment,
            tokenVariables: [(variable: "token", requestName: "Giriş")],
            secretNames: ["api-key"]
        )
    }

    func testEnvironmentValueLastEnabledWins() {
        XCTAssertEqual(preview("host"), .environment(environmentName: "Test", value: "son"), "gönderimdeki gibi son yazılan")
        XCTAssertEqual(preview("kapali"), .undefined(environmentName: "Test"))
        XCTAssertEqual(preview("yok", environment: .some(nil)), .undefined(environmentName: nil))
    }

    func testTokenOverridesEnvironmentAndHidesValue() {
        XCTAssertEqual(preview("token"), .token(requestName: "Giriş"))
    }

    func testSecretNeverCarriesValue() {
        XCTAssertEqual(preview("secret:api-key"), .secret(name: "api-key", exists: true))
        XCTAssertEqual(preview("secret: yok"), .secret(name: "yok", exists: false))
        XCTAssertFalse(preview("secret: yok").isDefined)
    }
}

final class TemplateVariableRangeTests: XCTestCase {
    func testRangesAreUTF16AndMatchSegments() {
        let text = "https://ö.test/{{ base }}/x/{{id}}"
        let ranges = TemplateVariables.variableRanges(in: text)
        XCTAssertEqual(ranges.map(\.name), ["base", "id"])
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: ranges[0].range), "{{ base }}")
        XCTAssertEqual(ns.substring(with: ranges[1].range), "{{id}}")
    }

    func testNoVariablesNoRanges() {
        XCTAssertTrue(TemplateVariables.variableRanges(in: "https://a.test/x").isEmpty)
    }
}
