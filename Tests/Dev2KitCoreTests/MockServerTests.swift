import Network
import XCTest
@testable import Dev2KitCore

/// Mocker sunucusu gerçek soketle (2026-11-07). Portlar her testte rastgele
/// bir üçlü: gerçek 8098–8100 ve paralel testler etkilenmesin.
final class MockServerTests: XCTestCase {
    private var servers: [MockServer] = []
    private var blockers: [NWListener] = []

    override func tearDown() async throws {
        for server in servers { await server.stop() }
        blockers.forEach { $0.cancel() }
        servers = []
        blockers = []
    }

    private func ports() -> [UInt16] {
        let base = UInt16.random(in: 20_000...39_000)
        return [base, base + 1, base + 2]
    }

    private func server(_ onEvent: @escaping @Sendable (MockLogEvent) -> Void = { _ in }) -> MockServer {
        let server = MockServer(onEvent: onEvent)
        servers.append(server)
        return server
    }

    private func send(_ method: String = "GET", _ url: String, body: String? = nil, headers: [String: String] = [:]) async throws -> (Int, String, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, String(decoding: data, as: UTF8.self), http)
    }

    /// Portu başka bir program gibi tutar. `host` nil: tüm adreslerde.
    private func occupy(_ port: UInt16, host: NWEndpoint.Host?) async throws {
        let parameters = NWParameters.tcp
        let listener: NWListener
        if let host {
            parameters.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        }
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "dinleyici hazır")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 3)
        blockers.append(listener)
    }

    private let pay = MockEndpoint(method: .post, path: "/bnpl-service/execute-payment/pay",
                                   response: MockResponse(body: #"{"result":"default"}"#),
                                   scenarios: [MockScenario(name: "red", conditions: [
                                       MockCondition(source: .jsonBody, name: "$.amount", comparison: .equals, value: "0"),
                                   ], response: MockResponse(status: 422, body: #"{"result":"declined"}"#))])

    func testServesDefaultAndScenarioOnFirstFreePort() async throws {
        let candidates = ports()
        let server = server()
        let port = try await server.start(endpoints: [pay], ports: candidates)
        XCTAssertEqual(port, candidates[0])
        let base = "http://127.0.0.1:\(port)/bnpl-service/execute-payment/pay"
        var result = try await send("POST", base, body: #"{"amount": 10}"#)
        XCTAssertEqual(result.0, 200)
        XCTAssertEqual(result.1, #"{"result":"default"}"#)
        XCTAssertEqual(result.2.value(forHTTPHeaderField: "Content-Type"), "application/json")
        result = try await send("POST", base, body: #"{"amount": 0}"#)
        XCTAssertEqual(result.0, 422)
        XCTAssertEqual(result.1, #"{"result":"declined"}"#)
        result = try await send("GET", "http://127.0.0.1:\(port)/yok")
        XCTAssertEqual(result.0, 404)
    }

    func testLocalhostOverIPv6AlsoWorks() async throws {
        let server = server()
        let port = try await server.start(endpoints: [pay], ports: ports())
        let result = try await send("POST", "http://[::1]:\(port)/bnpl-service/execute-payment/pay", body: "{}")
        XCTAssertEqual(result.0, 200)
    }

    func testSkipsBusyPortsIncludingAWildcardListener() async throws {
        let candidates = ports()
        // Başka bir program tüm adreslerde dinliyor: localhost trafiği çalınmamalı.
        try await occupy(candidates[0], host: nil)
        try await occupy(candidates[1], host: "127.0.0.1")
        let port = try await server().start(endpoints: [pay], ports: candidates)
        XCTAssertEqual(port, candidates[2])
    }

    func testAnotherProgramOnIPv6LoopbackMakesThePortBusy() async throws {
        let candidates = ports()
        try await occupy(candidates[0], host: "::1")
        let port = try await server().start(endpoints: [pay], ports: candidates)
        XCTAssertEqual(port, candidates[1], "localhost ::1'e giderse başka programa düşerdi")
    }

    /// Güvenlik: sunucu yalnızca bu Mac'ten erişilebilir. Mac'in ağ adresinden
    /// (ör. 192.168.x.x) bağlantı reddedilmeli.
    func testNotReachableFromTheNetworkAddress() async throws {
        guard let address = Self.networkAddress() else { throw XCTSkip("ağ adresi yok") }
        let server = server()
        let port = try await server.start(endpoints: [pay], ports: ports())
        do {
            _ = try await send("POST", "http://\(address):\(port)/bnpl-service/execute-payment/pay", body: "{}")
            XCTFail("ağ adresinden erişilmemeliydi (\(address))")
        } catch {
            // Beklenen: bağlantı kurulamaz.
        }
        let local = try await send("POST", "http://localhost:\(port)/bnpl-service/execute-payment/pay", body: "{}")
        XCTAssertEqual(local.0, 200, "localhost çalışır")
    }

    /// Geri döngü olmayan ilk IPv4 adresi.
    private static func networkAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    func testAllPortsBusyReportsThem() async throws {
        let candidates = ports()
        for port in candidates { try await occupy(port, host: "127.0.0.1") }
        do {
            _ = try await server().start(endpoints: [pay], ports: candidates)
            XCTFail("başlamamalıydı")
        } catch let error as MockServer.StartError {
            XCTAssertEqual(error, .portsInUse(candidates))
        }
    }

    func testUpdateKeepsThePortAndSwapsDefinitions() async throws {
        let server = server()
        let port = try await server.start(endpoints: [pay], ports: ports())
        var changed = pay
        changed.response.body = "yeni"
        server.update(endpoints: [changed])
        try await Task.sleep(for: .milliseconds(50))
        let result = try await send("POST", "http://127.0.0.1:\(port)/bnpl-service/execute-payment/pay", body: "{}")
        XCTAssertEqual(result.1, "yeni", "aynı portta yeni tanım")
    }

    func testStopFreesThePortForAnotherStart() async throws {
        let candidates = ports()
        let first = server()
        _ = try await first.start(endpoints: [pay], ports: candidates)
        await first.stop()
        let again = try await server().start(endpoints: [pay], ports: candidates)
        XCTAssertEqual(again, candidates[0])
    }

    func testDelayAndLogEvent() async throws {
        let events = EventBox()
        var slow = pay
        slow.response.delayMilliseconds = 300
        let server = server { events.append($0) }
        let port = try await server.start(endpoints: [slow], ports: ports())
        let start = ContinuousClock.now
        _ = try await send("POST", "http://127.0.0.1:\(port)/bnpl-service/execute-payment/pay?trace=1",
                           body: #"{"amount": 5}"#, headers: ["X-Trace": "abc"])
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(290))
        try await Task.sleep(for: .milliseconds(100))
        let event = try XCTUnwrap(events.all.last)
        XCTAssertEqual(event.method, "POST")
        XCTAssertEqual(event.target, "/bnpl-service/execute-payment/pay?trace=1")
        XCTAssertEqual(event.outcome, .defaultResponse)
        XCTAssertEqual(event.endpointID, slow.id)
        XCTAssertEqual(event.status, 200)
        XCTAssertEqual(event.bodyPreview, #"{"amount": 5}"#)
        XCTAssertTrue(event.headers.contains { $0.name.lowercased() == "x-trace" && $0.value == "abc" })
        XCTAssertGreaterThanOrEqual(event.milliseconds, 290)
    }

    func testDeeplyNestedBodyDoesNotCrash() async throws {
        let server = server()
        let port = try await server.start(endpoints: [pay], ports: ports())
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        let result = try await send("POST", "http://127.0.0.1:\(port)/bnpl-service/execute-payment/pay", body: deep)
        XCTAssertEqual(result.0, 200, "derin gövde varsayılana düşer, sunucu çökmez")
    }

    func testManySequentialRequestsReuseConnections() async throws {
        let server = server()
        let port = try await server.start(endpoints: [pay], ports: ports())
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for _ in 0..<50 {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/bnpl-service/execute-payment/pay")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            let (_, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MockLogEvent] = []

    func append(_ event: MockLogEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    var all: [MockLogEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// Kullanıcının durumu gerçek HTTP üzerinden: aynı servis, aynı header, farklı gövde.
final class MockServerBodyScenarioTests: XCTestCase {
    func testDifferentBodiesGetDifferentResponsesOverHTTP() async throws {
        let header = MockCondition(source: .header, name: "X-Channel", comparison: .equals, value: "mobile")
        let endpoint = MockEndpoint(method: .post, path: "/bnpl-service/execute-payment/pay",
                                    response: MockResponse(body: #"{"status":"APPROVED"}"#),
                                    scenarios: [MockScenario(name: "limit", conditions: [header],
                                                             response: MockResponse(status: 422, body: #"{"status":"LIMIT"}"#),
                                                             requestBody: #"{"amount": 50000}"#)])
        let server = MockServer()
        let base = UInt16.random(in: 20_000...39_000)
        let port = try await server.start(endpoints: [endpoint], ports: [base, base + 1, base + 2])
        defer { Task { await server.stop() } }
        func post(_ body: String) async throws -> (Int, String) {
            var request = URLRequest(url: URL(string: "http://localhost:\(port)/bnpl-service/execute-payment/pay")!)
            request.httpMethod = "POST"
            request.setValue("mobile", forHTTPHeaderField: "X-Channel")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        var result = try await post(#"{"requestId":"x1","amount":50000}"#)
        XCTAssertEqual(result.0, 422)
        XCTAssertEqual(result.1, #"{"status":"LIMIT"}"#)
        result = try await post(#"{"requestId":"x2","amount":100}"#)
        XCTAssertEqual(result.0, 200)
        XCTAssertEqual(result.1, #"{"status":"APPROVED"}"#)
    }
}
