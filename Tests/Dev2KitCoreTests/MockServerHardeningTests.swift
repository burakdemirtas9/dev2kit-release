import Darwin
import XCTest
@testable import Dev2KitCore

/// Güvenlik incelemesi (2026-11-07) bulgularının kalıcı testleri, ham soketle:
/// M1 DNS rebinding (yabancı Host), M2 sınırsız bellek büyümesi, M3 yavaş
/// damlatma. Saldırgan: tarayıcıdaki kötü niyetli site (M1) ya da bu Mac'teki
/// bir süreç (M2, M3).
final class MockServerHardeningTests: XCTestCase {
    private var server: MockServer?

    override func tearDown() async throws {
        await server?.stop()
    }

    private func start(readSeconds: Double = MockerLimits.requestReadSeconds) async throws -> UInt16 {
        let server = MockServer(requestReadSeconds: readSeconds)
        self.server = server
        let base = UInt16.random(in: 20_000...39_000)
        return try await server.start(endpoints: [
            MockEndpoint(path: "/a", response: MockResponse(body: "mock-veri")),
            MockEndpoint(path: "/slow", response: MockResponse(body: "yavaş", delayMilliseconds: 3_000)),
        ], ports: [base, base + 1, base + 2])
    }

    // MARK: Ham soket

    private func connect(_ port: UInt16, timeout: Int = 3) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(result, 0)
        return fd
    }

    @discardableResult
    private func write(_ fd: Int32, _ bytes: [UInt8]) -> Int {
        bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, bytes.count, 0) }
    }

    private func read(_ fd: Int32) -> String {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            out += buffer[0..<count]
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func exchange(_ port: UInt16, _ request: String) -> String {
        let fd = connect(port)
        defer { close(fd) }
        write(fd, Array(request.utf8))
        return read(fd)
    }

    // MARK: M1 — Host

    func testHostRule() {
        for host in ["localhost", "localhost:8098", "LOCALHOST.", "api.localhost:8098", "127.0.0.1", "127.1.2.3:80",
                     "[::1]", "[::1]:8098", "[0:0:0:0:0:0:0:1]", "[::ffff:127.0.0.1]"] {
            XCTAssertTrue(MockHostCheck.isLocal(MockHostCheck.hostName(host)), host)
        }
        for host in ["evil.test", "evil.test:8098", "localhost.evil.test", "127.0.0.1.evil.test", "0.0.0.0", "192.168.1.5",
                     "[::2]", "[::ffff:10.0.0.1]", "", "2130706433x"] {
            XCTAssertFalse(MockHostCheck.isLocal(MockHostCheck.hostName(host)), host)
        }
        let absolute = MockIncomingRequest(method: "GET", target: "http://evil.test/a", headers: [MockHeader(name: "Host", value: "localhost")])
        XCTAssertFalse(MockHostCheck.isAllowed(absolute), "mutlak hedefteki host da denetlenir")
        let twoHosts = MockIncomingRequest(method: "GET", target: "/a", headers: [
            MockHeader(name: "Host", value: "localhost"), MockHeader(name: "Host", value: "evil.test"),
        ])
        XCTAssertFalse(MockHostCheck.isAllowed(twoHosts), "çift Host reddedilir")
        XCTAssertTrue(MockHostCheck.isAllowed(MockIncomingRequest(method: "GET", target: "/a")), "Host'suz HTTP/1.0")
    }

    func testForeignHostGets403WithoutMockData() async throws {
        let port = try await start()
        let rejected = exchange(port, "GET /a HTTP/1.1\r\nHost: evil.attacker.test:\(port)\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(rejected.hasPrefix("HTTP/1.1 403 "), rejected)
        XCTAssertFalse(rejected.contains("mock-veri"), "mock verisi sızmaz")
        for host in ["localhost:\(port)", "127.0.0.1:\(port)", "[::1]:\(port)"] {
            let allowed = exchange(port, "GET /a HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n")
            XCTAssertTrue(allowed.hasPrefix("HTTP/1.1 200 ") && allowed.hasSuffix("mock-veri"), host)
        }
        XCTAssertTrue(exchange(port, "GET /a HTTP/1.0\r\n\r\n").hasSuffix("mock-veri"), "Host'suz HTTP/1.0")
    }

    func testRouterRejectsBeforeMatching() {
        let route = MockRouter.route(MockIncomingRequest(method: "GET", target: "/a", headers: [MockHeader(name: "Host", value: "evil.test")]),
                                     endpoints: [MockEndpoint(path: "/a")])
        XCTAssertEqual(route.outcome, .forbiddenHost)
        XCTAssertEqual(route.response.status, 403)
        XCTAssertNil(route.endpointID)
    }

    // MARK: M2 — Sınırsız birikme

    func testFloodWhileWaitingForAResponseClosesTheConnection() async throws {
        let port = try await start()
        let fd = connect(port, timeout: 5)
        defer { close(fd) }
        write(fd, Array("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
        let chunk = [UInt8](repeating: 65, count: 1_048_576)
        var sent = 0
        for _ in 0..<40 {
            let count = write(fd, chunk)
            if count <= 0 { break }
            sent += count
        }
        // Sınır: 2 × 64 KB + 10 MB. Sunucu bağlantıyı kapatır; yanıt gelmez.
        let reply = read(fd)
        XCTAssertFalse(reply.contains("yavaş"), "taşan bağlantıya yanıt verilmedi")
        XCTAssertLessThan(sent, 40 * 1_048_576, "sunucu kapattığı için yazma kesildi")
    }

    // MARK: M3 — Yavaş damlatma

    func testSlowTrickleIsCutAtTheReadDeadline() async throws {
        let port = try await start(readSeconds: 1)
        let fd = connect(port, timeout: 5)
        defer { close(fd) }
        write(fd, Array("GET /a HTTP/1.1\r\n".utf8))
        let started = Date()
        var reply = ""
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(250))
            if write(fd, Array("X-A: b\r\n".utf8)) <= 0 { break }
        }
        reply = read(fd)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 408 "), reply)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5, "damlatma süreyi uzatamaz")
    }

    func testNormalKeepAliveIsUnaffected() async throws {
        let port = try await start(readSeconds: 1)
        let fd = connect(port, timeout: 3)
        defer { close(fd) }
        for _ in 0..<3 {
            write(fd, Array("GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = recv(fd, &buffer, buffer.count, 0)
            XCTAssertTrue(String(decoding: buffer[0..<max(count, 0)], as: UTF8.self).hasSuffix("mock-veri"))
            try await Task.sleep(for: .milliseconds(1_200))
        }
    }
}
