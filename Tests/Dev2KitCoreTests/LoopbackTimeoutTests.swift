import XCTest
import Darwin
@testable import Dev2KitCore

/// OAuth callback dinleyicisinin süre sınırı (güvenlik incelemesi,
/// 2026-10-20): zamanlayıcı engelleyen `accept` ile aynı kuyrukta olduğu
/// için hiç çalışmıyordu; bağlantı gelmezse bekleme bitmiyordu.
final class LoopbackTimeoutTests: XCTestCase {
    func testTimesOutWhenNobodyConnects() async throws {
        let receiver = try LoopbackReceiver()
        let start = Date()
        do {
            _ = try await receiver.waitForCallback(timeout: 0.3)
            XCTFail("süre dolmalı")
        } catch let error as LoopbackReceiver.ReceiverError {
            XCTAssertEqual(error.message, L10n.t("loopback.timeout"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Yerel bir süreç bağlanıp sessiz kalırsa da süre işler.
    func testSilentConnectionDoesNotBlockTheTimeout() async throws {
        let receiver = try LoopbackReceiver()
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = receiver.port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        let start = Date()
        do {
            _ = try await receiver.waitForCallback(timeout: 0.5)
            XCTFail("sessiz bağlantı callback sayılmamalı")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testStopEndsTheWaitPromptly() async throws {
        let receiver = try LoopbackReceiver()
        let start = Date()
        Task { try? await Task.sleep(for: .milliseconds(200)); receiver.stop() }
        do {
            _ = try await receiver.waitForCallback(timeout: 30)
            XCTFail("durdurulunca bitmeli")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Kontrol: normal callback hâlâ alınıyor.
    func testCallbackIsReceived() async throws {
        let receiver = try LoopbackReceiver()
        let uri = receiver.redirectURI
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            _ = try? await URLSession.shared.data(from: URL(string: uri + "?code=SYNTHETIC&state=s")!)
        }
        let url = try await receiver.waitForCallback(timeout: 5)
        XCTAssertEqual(url.path, "/callback")
        XCTAssertTrue(url.absoluteString.contains("code=SYNTHETIC"))
    }

    private func connectedClient(to receiver: LoopbackReceiver) -> Int32 {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        // Testin kendi yazımı da SIGPIPE üretmesin: sinyal yalnızca alıcıdan gelebilsin.
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = receiver.port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        return client
    }

    /// Sessiz bir yerel bağlantı gerçek callback'i süre dolana kadar
    /// bekletmemeli: okuma bağlantı başına 5 sn (yeniden tarama).
    func testSilentConnectionDoesNotHoldBackTheRealCallback() async throws {
        let receiver = try LoopbackReceiver()
        let silent = connectedClient(to: receiver)
        defer { close(silent) }
        let uri = receiver.redirectURI
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            _ = try? await URLSession.shared.data(from: URL(string: uri + "?code=SYNTHETIC&state=s")!)
        }
        let start = Date()
        let url = try await receiver.waitForCallback(timeout: 30)
        XCTAssertTrue(url.absoluteString.contains("code=SYNTHETIC"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 12, "sessiz bağlantı en çok 5 sn tutar")
    }

    /// Bağlantıyı RST ile koparan istemci süreci SIGPIPE ile öldürmemeli
    /// (yeniden tarama: exit 141). Ardından gelen gerçek callback alınır.
    func testAbortedClientDoesNotKillTheProcess() async throws {
        let receiver = try LoopbackReceiver()
        let uri = receiver.redirectURI
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            for _ in 0..<5 {
                let client = connectedClient(to: receiver)
                let request = Array("GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
                _ = request.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
                setsockopt(client, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
                close(client)
                // Dinleyicinin kuyruğu tek kişilik (`listen(_, 1)`): sıradakinden önce boşalsın.
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(200))
            _ = try? await URLSession.shared.data(from: URL(string: uri + "?code=SYNTHETIC&state=s")!)
        }
        let url = try await receiver.waitForCallback(timeout: 10)
        XCTAssertTrue(url.absoluteString.contains("code=SYNTHETIC"))
    }
}
