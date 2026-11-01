import Darwin
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Uçuştaki istek yeniden gönderilince iptal edilen eski görev yeni
/// gönderimin durumunu ezmemeli (yeniden tarama, 2026-11-01): eskiden
/// koşulsuz `.idle` ve `inFlight[id] = nil` yazıyor, "yükleniyor" kayboluyor
/// ve ⌘. yeni gönderimi iptal edemiyordu (POST farkında olmadan tekrarlanabilir).
@MainActor
final class SendGenerationTests: XCTestCase {
    private var harness: AppStateHarness!
    private var listener: Int32 = -1

    override func setUp() async throws {
        harness = AppStateHarness()
    }

    override func tearDown() async throws {
        if listener >= 0 { close(listener) }
        harness.tearDown()
    }

    /// Bağlantıyı kabul edip hiç yanıt vermeyen dinleyici: `accept` edilmez,
    /// bağlantı çekirdek kuyruğunda kurulur, istek yanıt beklerken asılı kalır.
    /// Yalnızca 127.0.0.1; ağa trafik çıkmaz.
    private func silentPort() throws -> UInt16 {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 8), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    func testResendKeepsTheNewSendLoadingAndCancellable() async throws {
        let state = harness.state
        let request = harness.addRequest(named: "Yavaş", url: "http://127.0.0.1:\(try silentPort())/yavas")
        state.selectedRequestID = request.id

        state.send(request)
        try await Task.sleep(for: .milliseconds(300))
        state.send(request)
        // İlk görev iptal edildi; catch dalının çalışmasına zaman tanınır.
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertTrue(state.isSending, "yeni gönderim hâlâ yükleniyor")
        XCTAssertNotNil(state.inFlight[request.id], "⌘. için tutamaç yerinde")

        state.cancelSend(request.id)
        XCTAssertFalse(state.isSending)
        XCTAssertNil(state.inFlight[request.id])
    }
}
