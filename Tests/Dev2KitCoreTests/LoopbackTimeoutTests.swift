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
}
