import XCTest
@testable import Dev2KitCore

/// Senaryonun request body'si (kullanıcı isteği, 2026-11-07): "aynı servis,
/// aynı header, farklı body → farklı response".
final class MockBodyMatchTests: XCTestCase {
    private func json(_ text: String) -> JSONValue { try! JSONDocument.parse(text) }

    func testContainsIgnoresExtraFieldsOrderAndNumberFormat() {
        let actual = json(#"{"requestId": "r-1", "amount": 100.0, "card": {"type": "VISA", "last4": "1234"}, "items": [1, 2]}"#)
        XCTAssertTrue(MockBodyMatcher.contains(actual, json(#"{"amount": 100}"#)))
        XCTAssertTrue(MockBodyMatcher.contains(actual, json(#"{"card": {"type": "VISA"}, "amount": 1e2}"#)), "iç içe ve sırasız")
        XCTAssertTrue(MockBodyMatcher.contains(actual, json(#"{"items": [1, 2]}"#)))
        XCTAssertFalse(MockBodyMatcher.contains(actual, json(#"{"items": [1]}"#)), "dizi aynı uzunlukta olmalı")
        XCTAssertFalse(MockBodyMatcher.contains(actual, json(#"{"amount": 101}"#)))
        XCTAssertFalse(MockBodyMatcher.contains(actual, json(#"{"currency": "TRY"}"#)), "olmayan alan")
        XCTAssertFalse(MockBodyMatcher.contains(actual, json(#"{"amount": "100"}"#)), "metin ≠ sayı")
    }

    func testExactRequiresSameFields() {
        let actual = json(#"{"b": 2, "a": [1, {"x": null}]}"#)
        XCTAssertTrue(MockBodyMatcher.equal(actual, json(#"{"a": [1, {"x": null}], "b": 2.0}"#)))
        XCTAssertFalse(MockBodyMatcher.equal(actual, json(#"{"a": [1, {"x": null}]}"#)), "eksik alan")
        XCTAssertFalse(MockBodyMatcher.equal(json(#"{"a": 1, "c": 3}"#), json(#"{"a": 1}"#)), "fazla alan")
    }

    func testTextBodies() {
        let example = MockBodyMatcher.example("  status=FAIL ")
        XCTAssertTrue(MockBodyMatcher.matches(example, mode: .contains, actualText: "id=1&status=FAIL", actualJSON: { nil }))
        XCTAssertFalse(MockBodyMatcher.matches(example, mode: .exact, actualText: "id=1&status=FAIL", actualJSON: { nil }))
        XCTAssertTrue(MockBodyMatcher.matches(example, mode: .exact, actualText: "status=FAIL\n", actualJSON: { nil }))
        XCTAssertTrue(MockBodyMatcher.matches(MockBodyMatcher.example(""), mode: .exact, actualText: "her şey", actualJSON: { nil }),
                      "boş örnek gövdeye bakmaz")
    }

    /// Kullanıcının durumu: aynı endpoint, aynı header, farklı gövde.
    func testSameServiceSameHeaderDifferentBody() {
        let header = MockCondition(source: .header, name: "X-Channel", comparison: .equals, value: "mobile")
        let endpoint = MockEndpoint(method: .post, path: "/bnpl-service/execute-payment/pay",
                                    response: MockResponse(body: "APPROVED"),
                                    scenarios: [
                                        MockScenario(name: "limit", conditions: [header],
                                                     response: MockResponse(status: 422, body: "LIMIT"),
                                                     requestBody: #"{"amount": 50000}"#),
                                        MockScenario(name: "kart", conditions: [header],
                                                     response: MockResponse(status: 402, body: "CARD"),
                                                     requestBody: #"{"card": {"blocked": true}}"#),
                                    ],
                                    requestBody: #"{"amount": 100, "card": {"blocked": false}}"#)
        func send(_ body: String) -> MockRoute {
            MockRouter.route(MockIncomingRequest(method: "POST", target: "/bnpl-service/execute-payment/pay",
                                                 headers: [MockHeader(name: "X-Channel", value: "mobile")],
                                                 body: Data(body.utf8)), endpoints: [endpoint])
        }
        XCTAssertEqual(send(#"{"requestId": "a1", "amount": 50000, "card": {"blocked": false}}"#).response.body, "LIMIT")
        XCTAssertEqual(send(#"{"requestId": "a2", "amount": 10, "card": {"blocked": true}}"#).response.body, "CARD")
        XCTAssertEqual(send(#"{"requestId": "a3", "amount": 10, "card": {"blocked": false}}"#).response.body, "APPROVED")
        let noHeader = MockRouter.route(MockIncomingRequest(method: "POST", target: "/bnpl-service/execute-payment/pay",
                                                            body: Data(#"{"amount": 50000}"#.utf8)), endpoints: [endpoint])
        XCTAssertEqual(noHeader.outcome, .defaultResponse, "header koşulu da tutmalı")
    }

    func testBodyOnlyScenarioIsActiveAndExactModeIsStrict() {
        let endpoint = MockEndpoint(path: "/a", response: MockResponse(body: "default"), scenarios: [
            MockScenario(response: MockResponse(body: "exact"), requestBody: #"{"a": 1}"#, bodyMatch: .exact),
        ])
        func body(_ text: String) -> String {
            MockRouter.route(MockIncomingRequest(method: "POST", target: "/a", body: Data(text.utf8)), endpoints: [endpoint]).response.body
        }
        XCTAssertEqual(body(#"{ "a" : 1.0 }"#), "exact")
        XCTAssertEqual(body(#"{"a": 1, "b": 2}"#), "default", "birebirde fazla alan eşleşmez")
        XCTAssertEqual(body("bozuk"), "default")
        XCTAssertTrue(MockValidator.issues(for: [endpoint]).isEmpty, "yalnız gövdeli senaryo uyarı almaz")
    }

    func testShadowedScenariosAreReported() {
        let general = MockScenario(name: "genel", requestBody: #"{"amount": 100}"#)
        let specific = MockScenario(name: "özel", requestBody: #"{"amount": 100, "currency": "TRY"}"#)
        var endpoint = MockEndpoint(path: "/pay", scenarios: [general, specific])
        var issues = MockValidator.issues(for: [endpoint])
        let shadow = issues.first { $0.scenarioID == specific.id }
        XCTAssertEqual(shadow?.severity, .error, "üstteki daha genel: alttaki hiç seçilmez")
        XCTAssertTrue(shadow?.message.contains("genel") == true)

        endpoint.scenarios = [specific, general]
        XCTAssertTrue(MockValidator.issues(for: [endpoint]).isEmpty, "belirgin olan üstteyse sorun yok")

        // Üstteki birebir, alttaki "içeriyorsa": alttaki daha çok istek yakalar, gölge yok.
        endpoint.scenarios = [MockScenario(requestBody: #"{"a": 1}"#, bodyMatch: .exact), MockScenario(requestBody: #"{"a": 1}"#)]
        XCTAssertTrue(MockValidator.issues(for: [endpoint]).isEmpty)

        // Üstte yalnız koşul, altta aynı koşul + gövde: üstteki hepsini yakalar.
        let header = MockCondition(source: .header, name: "X-A", comparison: .equals, value: "1")
        endpoint.scenarios = [MockScenario(conditions: [header]), MockScenario(conditions: [header], requestBody: #"{"a": 1}"#)]
        issues = MockValidator.issues(for: [endpoint])
        XCTAssertEqual(issues.first { $0.scenarioID == endpoint.scenarios[1].id }?.severity, .error)
    }

    func testOldScenariosDecodeWithoutBody() throws {
        let json = #"{"endpoints":[{"path":"/a","scenarios":[{"conditions":[{"source":"query","name":"x"}]}]}]}"#
        let scenario = try XCTUnwrap(try JSONDecoder().decode(MockerDocument.self, from: Data(json.utf8)).endpoints.first?.scenarios.first)
        XCTAssertEqual(scenario.requestBody, "")
        XCTAssertEqual(scenario.bodyMatch, .contains)
        XCTAssertTrue(scenario.isActive)
    }
}
