import XCTest
@testable import Dev2KitCore

/// Mocker kuralları (2026-11-07): yol deseni, eşleşme önceliği, senaryo
/// koşulları, çakışma uyarıları, HTTP okuma/yazma, kalıcılık.
final class MockerRulesTests: XCTestCase {
    private func request(_ method: String, _ target: String, headers: [MockHeader] = [], body: String = "") -> MockIncomingRequest {
        MockIncomingRequest(method: method, target: target, headers: headers, body: Data(body.utf8))
    }

    private func endpoint(_ method: MockMethod = .any, _ path: String, body: String = "default", scenarios: [MockScenario] = []) -> MockEndpoint {
        MockEndpoint(method: method, path: path, response: MockResponse(body: body), scenarios: scenarios)
    }

    private func scenario(_ name: String, _ conditions: [MockCondition], body: String) -> MockScenario {
        MockScenario(name: name, conditions: conditions, response: MockResponse(status: 201, body: body))
    }

    // MARK: Yol

    func testPathPatternMatching() {
        let pattern = MockPathPattern("/orders/{id}/items/*")
        XCTAssertEqual(pattern.match("/orders/42/items/7"), ["id": "42"])
        XCTAssertEqual(pattern.match("/orders/42/items/7?x=1"), ["id": "42"], "query yoksayılır")
        XCTAssertEqual(pattern.match("/orders/a%20b/items/x/"), ["id": "a b"], "yüzde kodu çözülür, sondaki / önemsiz")
        XCTAssertNil(pattern.match("/orders/42/items"))
        XCTAssertNil(pattern.match("/orders/42/other/7"))
        XCTAssertEqual(MockPathPattern("/bnpl-service/execute-payment/pay").match("/bnpl-service/execute-payment/pay"), [:])
        XCTAssertNil(MockPathPattern("/Pay").match("/pay"), "yol büyük/küçük harf duyarlı")
    }

    func testOverlapAndShape() {
        let literal = MockPathPattern("/orders/42")
        let parameter = MockPathPattern("/orders/{id}")
        let wildcard = MockPathPattern("/orders/*")
        XCTAssertTrue(literal.overlaps(parameter))
        XCTAssertFalse(literal.hasSameShape(as: parameter))
        XCTAssertTrue(parameter.hasSameShape(as: wildcard), "{id} ve * aynı yolları karşılar")
        XCTAssertFalse(MockPathPattern("/a/{x}").overlaps(MockPathPattern("/b/{y}")))
        XCTAssertFalse(MockPathPattern("/a").overlaps(MockPathPattern("/a/b")))
    }

    func testPathValidation() {
        XCTAssertNil(MockValidator.pathError("/bnpl-service/execute-payment/pay"))
        XCTAssertNil(MockValidator.pathError("/orders/{id}/*"))
        XCTAssertNotNil(MockValidator.pathError("bnpl/pay"))
        XCTAssertNotNil(MockValidator.pathError("/a b"))
        XCTAssertNotNil(MockValidator.pathError("/a?x=1"))
        XCTAssertNotNil(MockValidator.pathError("/orders/id{x}"))
        XCTAssertNotNil(MockValidator.pathError("/orders/{}"))
        XCTAssertNotNil(MockValidator.pathError("/a/{id}/b/{id}"))
    }

    // MARK: Yönlendirme

    func testDefaultResponseWhenNoScenario() {
        let route = MockRouter.route(request("POST", "/bnpl-service/execute-payment/pay"),
                                     endpoints: [endpoint(.post, "/bnpl-service/execute-payment/pay")])
        XCTAssertEqual(route.outcome, .defaultResponse)
        XCTAssertEqual(route.response.body, "default")
    }

    func testMethodFiltering() {
        let endpoints = [endpoint(.get, "/a", body: "get"), endpoint(.post, "/a", body: "post")]
        XCTAssertEqual(MockRouter.route(request("POST", "/a"), endpoints: endpoints).response.body, "post")
        XCTAssertEqual(MockRouter.route(request("GET", "/a"), endpoints: endpoints).response.body, "get")
        XCTAssertEqual(MockRouter.route(request("HEAD", "/a"), endpoints: endpoints).response.body, "get", "GET tanımı HEAD'i karşılar")
        let missing = MockRouter.route(request("DELETE", "/a"), endpoints: endpoints)
        XCTAssertEqual(missing.outcome, .noEndpoint)
        XCTAssertEqual(missing.response.status, 404)
        XCTAssertTrue(missing.response.body.contains("No mock endpoint for DELETE /a"))
    }

    func testPrecedenceSpecificPathThenMethodThenOrder() {
        let endpoints = [
            endpoint(.any, "/orders/{id}", body: "param-any"),
            endpoint(.post, "/orders/{id}", body: "param-post"),
            endpoint(.any, "/orders/42", body: "literal"),
            endpoint(.post, "/orders/{x}", body: "param-post-later"),
        ]
        XCTAssertEqual(MockRouter.route(request("GET", "/orders/42"), endpoints: endpoints).response.body, "literal")
        XCTAssertEqual(MockRouter.route(request("POST", "/orders/7"), endpoints: endpoints).response.body, "param-post")
        XCTAssertEqual(MockRouter.route(request("GET", "/orders/7"), endpoints: endpoints).response.body, "param-any")
    }

    func testScenarioConditions() {
        let pay = endpoint(.post, "/pay/{channel}", scenarios: [
            scenario("büyük tutar", [MockCondition(source: .jsonBody, name: "$.amount", comparison: .equals, value: "1000")], body: "large"),
            scenario("mobil", [
                MockCondition(source: .header, name: "x-channel", comparison: .equals, value: "mobile"),
                MockCondition(source: .query, name: "debug", comparison: .exists),
            ], body: "mobile"),
            scenario("kanal", [MockCondition(source: .pathParameter, name: "{channel}", comparison: .equals, value: "web")], body: "web"),
            scenario("hata", [MockCondition(source: .bodyText, comparison: .contains, value: "FAIL")], body: "fail"),
            scenario("koşulsuz", [], body: "never"),
        ])
        func body(_ r: MockIncomingRequest) -> String { MockRouter.route(r, endpoints: [pay]).response.body }

        XCTAssertEqual(body(request("POST", "/pay/app", body: #"{"amount": 1000.0}"#)), "large", "JSON sayısı 1000 = 1000.0")
        XCTAssertEqual(body(request("POST", "/pay/app", body: #"{"amount": 999}"#)), "default")
        XCTAssertEqual(body(request("POST", "/pay/app?debug", headers: [MockHeader(name: "X-Channel", value: " mobile ")])), "mobile",
                       "header adı büyük/küçük harf duyarsız, değer kırpılır")
        XCTAssertEqual(body(request("POST", "/pay/app", headers: [MockHeader(name: "X-Channel", value: "mobile")])), "default",
                       "tüm koşullar tutmalı")
        XCTAssertEqual(body(request("POST", "/pay/web")), "web")
        XCTAssertEqual(body(request("POST", "/pay/app", body: "status=FAIL")), "fail")
        XCTAssertEqual(body(request("POST", "/pay/app", body: "not json")), "default", "bozuk JSON eşleşmez")
        let route = MockRouter.route(request("POST", "/pay/web"), endpoints: [pay])
        XCTAssertEqual(route.response.status, 201)
        if case .scenario(_, let name) = route.outcome { XCTAssertEqual(name, "kanal") } else { XCTFail("senaryo bekleniyordu") }
    }

    func testConditionComparisons() {
        func matches(_ condition: MockCondition, _ r: MockIncomingRequest) -> Bool {
            let ep = endpoint(.any, "/x", scenarios: [scenario("s", [condition], body: "hit")])
            return MockRouter.route(r, endpoints: [ep]).response.body == "hit"
        }
        let json = request("POST", "/x?tag=a&tag=b&q=a+b", body: #"{"user": {"tier": "gold", "tags": ["x", "y"]}, "ok": true, "n": null}"#)
        XCTAssertTrue(matches(MockCondition(source: .jsonBody, name: "$.user.tier", comparison: .equals, value: "gold"), json))
        XCTAssertTrue(matches(MockCondition(source: .jsonBody, name: "$.user.tags[*]", comparison: .equals, value: "y"), json), "birden çok değerden biri")
        XCTAssertTrue(matches(MockCondition(source: .jsonBody, name: "$.ok", comparison: .equals, value: "true"), json))
        XCTAssertTrue(matches(MockCondition(source: .jsonBody, name: "$.n", comparison: .equals, value: "null"), json))
        XCTAssertTrue(matches(MockCondition(source: .jsonBody, name: "$.user.tags", comparison: .equals, value: #"["x","y"]"#), json))
        XCTAssertTrue(matches(MockCondition(source: .jsonBody, name: "$.missing", comparison: .notEquals, value: "x"), json), "alan yoksa eşit değil")
        XCTAssertFalse(matches(MockCondition(source: .jsonBody, name: "$.missing", comparison: .exists), json))
        XCTAssertTrue(matches(MockCondition(source: .jsonBody, name: "$.user.tier", comparison: .contains, value: "ol"), json))
        XCTAssertTrue(matches(MockCondition(source: .query, name: "tag", comparison: .equals, value: "b"), json))
        XCTAssertTrue(matches(MockCondition(source: .query, name: "q", comparison: .equals, value: "a b"), json), "+ boşluk olur")
        XCTAssertFalse(matches(MockCondition(source: .header, name: "X-Missing", comparison: .exists), json))
        XCTAssertFalse(matches(MockCondition(source: .bodyText, comparison: .contains, value: ""), json), "boş 'içerir' her şeyi yakalamaz")
    }

    func testStatusAndDelayAreClamped() {
        let response = MockResponse(status: 42, delayMilliseconds: 10_000_000).clamped
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.delayMilliseconds, MockerLimits.maxDelayMilliseconds)
        XCTAssertEqual(MockResponse(delayMilliseconds: -5).clamped.delayMilliseconds, 0)
    }

    // MARK: Çakışma uyarıları

    func testDuplicateEndpointIsReported() {
        let first = endpoint(.post, "/pay")
        let second = endpoint(.post, "/pay/")
        let issues = MockValidator.issues(for: [first, second])
        XCTAssertTrue(issues.contains { $0.endpointID == second.id && $0.severity == .error }, "alttaki hiç yanıt vermez")
        XCTAssertTrue(issues.contains { $0.endpointID == first.id && $0.severity == .warning })
    }

    func testOverlapNamesTheWinner() {
        let general = endpoint(.any, "/orders/{id}")
        let specific = endpoint(.any, "/orders/42")
        let issues = MockValidator.issues(for: [general, specific])
        let message = try? XCTUnwrap(issues.first { $0.endpointID == general.id }?.message)
        XCTAssertTrue(message?.contains("Any /orders/42") == true, message ?? "")
        XCTAssertEqual(issues.filter { $0.endpointID == specific.id }.count, 1, "iki tarafta da görünür")
        XCTAssertTrue(MockValidator.issues(for: [endpoint(.get, "/a"), endpoint(.post, "/a")]).isEmpty, "metot farklı: çakışma yok")
        XCTAssertTrue(MockValidator.issues(for: [endpoint(.any, "/a/{x}"), endpoint(.any, "/b/{x}")]).isEmpty)
        XCTAssertFalse(MockValidator.issues(for: [endpoint(.any, "/a"), endpoint(.post, "/a")]).isEmpty, "Any ile POST örtüşür")
    }

    func testScenarioIssues() {
        let headerCondition = MockCondition(source: .header, name: "X-A", comparison: .equals, value: "1")
        let ep = endpoint(.post, "/pay/{id}", scenarios: [
            scenario("ilk", [headerCondition], body: "a"),
            scenario("aynı", [MockCondition(source: .header, name: "x-a", comparison: .equals, value: "1 ")], body: "b"),
            scenario("", [], body: "c"),
            scenario("hatalı", [
                MockCondition(source: .jsonBody, name: "amount[", comparison: .exists),
                MockCondition(source: .pathParameter, name: "orderId", comparison: .exists),
                MockCondition(source: .query, name: "", comparison: .exists),
            ], body: "d"),
        ])
        let issues = MockValidator.issues(for: [ep])
        let same = issues.first { $0.scenarioID == ep.scenarios[1].id }
        XCTAssertEqual(same?.severity, .error)
        XCTAssertTrue(same?.message.contains("ilk") == true)
        XCTAssertTrue(issues.contains { $0.scenarioID == ep.scenarios[2].id && $0.severity == .warning }, "koşulsuz senaryo")
        XCTAssertEqual(issues.filter { $0.scenarioID == ep.scenarios[3].id && $0.conditionID != nil }.count, 3)
    }

    // MARK: HTTP okuma

    private func read(_ chunks: [String], reader: inout MockHTTPReader) -> [MockHTTPReader.Event] {
        var events: [MockHTTPReader.Event] = []
        for chunk in chunks {
            reader.append(Data(chunk.utf8))
            while true {
                let event = reader.next()
                if case .needMore = event { break }
                events.append(event)
                if case .failure = event { return events }
            }
        }
        return events
    }

    func testReaderHandlesSplitContentLengthAndPipelining() {
        var reader = MockHTTPReader()
        let events = read([
            "POST /pay?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Le",
            "ngth: 5\r\n\r\nhel",
            "loGET /a HTTP/1.1\r\nConnection: close\r\n\r\n",
        ], reader: &reader)
        XCTAssertEqual(events.count, 2)
        guard case .request(let first, let keepAlive) = events[0], case .request(let second, let secondKeepAlive) = events[1] else {
            return XCTFail("\(events)")
        }
        XCTAssertEqual(first.method, "POST")
        XCTAssertEqual(first.path, "/pay")
        XCTAssertEqual(String(decoding: first.body, as: UTF8.self), "hello")
        XCTAssertTrue(keepAlive)
        XCTAssertEqual(second.target, "/a")
        XCTAssertFalse(secondKeepAlive)
    }

    func testReaderDecodesChunkedBody() {
        var reader = MockHTTPReader()
        let events = read([
            "POST /c HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\n",
            "0\r\nX-Trailer: 1\r\n\r\n",
        ], reader: &reader)
        guard case .request(let request, _) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "Wikipedia")
    }

    func testReaderExpectContinueAndLimits() {
        var reader = MockHTTPReader()
        var events = read(["PUT /u HTTP/1.1\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n"], reader: &reader)
        guard case .continueExpected = events.first else { return XCTFail("\(events)") }
        events = read(["abc"], reader: &reader)
        guard case .request = events.first else { return XCTFail("\(events)") }

        var small = MockHTTPReader(maxHeadBytes: 64, maxBodyBytes: 10)
        events = read(["POST / HTTP/1.1\r\nContent-Length: 11\r\n\r\n"], reader: &small)
        guard case .failure(413) = events.first else { return XCTFail("\(events)") }
        small = MockHTTPReader(maxHeadBytes: 64, maxBodyBytes: 10)
        events = read(["GET / HTTP/1.1\r\nX-Long: " + String(repeating: "a", count: 100)], reader: &small)
        guard case .failure(431) = events.first else { return XCTFail("\(events)") }
        var bad = MockHTTPReader()
        events = read(["NONSENSE\r\n\r\n"], reader: &bad)
        guard case .failure(400) = events.first else { return XCTFail("\(events)") }
    }

    // MARK: HTTP yazma

    func testWriterManagesHeadersAndBlocksInjection() {
        let response = MockResponse(status: 201, headers: [
            KeyValueEntry(key: "X-Ok", value: "a\r\nSet-Cookie: kötü=1"),
            KeyValueEntry(key: "Content-Length", value: "999"),
            KeyValueEntry(key: "Bad Name", value: "x"),
            KeyValueEntry(key: "X-Off", value: "x", enabled: false),
        ], body: #"{"ok":true}"#)
        let text = String(decoding: MockHTTPWriter.data(for: response, method: "POST", keepAlive: true), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 201 Created\r\n"))
        XCTAssertTrue(text.contains("X-Ok: a  Set-Cookie: kötü=1\r\n"), "satır sonu boşluk olur, yeni başlık açılmaz")
        XCTAssertFalse(text.contains("\r\nSet-Cookie"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertFalse(text.contains("999"))
        XCTAssertFalse(text.contains("Bad Name"))
        XCTAssertFalse(text.contains("X-Off"))
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(text.contains("Connection: keep-alive\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))

        let head = String(decoding: MockHTTPWriter.data(for: MockResponse(body: "abc"), method: "HEAD", keepAlive: false), as: UTF8.self)
        XCTAssertTrue(head.contains("Content-Length: 3"))
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"), "HEAD'de gövde yok")
        let noContent = String(decoding: MockHTTPWriter.data(for: MockResponse(status: 204, body: "x"), method: "GET", keepAlive: false), as: UTF8.self)
        XCTAssertFalse(noContent.contains("Content-Length"))
    }

    // MARK: Kalıcılık

    func testStoreRoundTripAndCorruptFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mocker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MockerStore(root: root)
        XCTAssertEqual(store.load(), .missing)
        let document = MockerDocument(endpoints: [endpoint(.post, "/pay", scenarios: [
            scenario("s", [MockCondition(source: .query, name: "a", comparison: .exists)], body: "x"),
        ])])
        try store.save(document)
        XCTAssertEqual(store.load(), .loaded(document))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try Data("bozuk".utf8).write(to: store.url)
        guard case .corrupt(let name) = store.load() else { return XCTFail("bozuk dosya") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mocker/\(name)").path), "silinmez, kenara alınır")
        XCTAssertEqual(store.load(), .missing)
    }

    func testDecodingToleratesMissingFields() throws {
        let json = #"{"endpoints":[{"path":"/a","scenarios":[{"conditions":[{"source":"query","name":"x"}]}]}]}"#
        let document = try JSONDecoder().decode(MockerDocument.self, from: Data(json.utf8))
        XCTAssertEqual(document.endpoints.first?.method, .any)
        XCTAssertEqual(document.endpoints.first?.scenarios.first?.conditions.first?.comparison, .equals)
        XCTAssertEqual(document.endpoints.first?.response.status, 200)
    }
}
