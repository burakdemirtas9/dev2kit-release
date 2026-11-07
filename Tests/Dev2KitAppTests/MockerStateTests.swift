import AppKit
import Network
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Mocker modunun durumu (2026-11-07): başlat / uygula / durdur, port
/// mesajı, kalıcılık, boşta tüketim ve ekran. Her test geçici veri dizini ve
/// rastgele port üçlüsüyle: gerçek 8098–8100 ve kullanıcının tanımları elleşilmez.
@MainActor
final class MockerStateTests: XCTestCase {
    private var root: URL!
    private var states: [MockerState] = []
    private var blockers: [NWListener] = []
    private var window: NSWindow?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mocker-state-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        for state in states { await state.stop() }
        blockers.forEach { $0.cancel() }
        window?.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeState() -> MockerState {
        let base = UInt16.random(in: 20_000...39_000)
        let state = MockerState(root: root, ports: [base, base + 1, base + 2])
        states.append(state)
        return state
    }

    private func get(_ url: String, method: String = "GET") async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    func testStartApplyAndStop() async throws {
        let state = makeState()
        let id = try XCTUnwrap(state.addEndpoint())
        state.endpoints[0].path = "/bnpl-service/execute-payment/pay"
        state.endpoints[0].response.body = #"{"v":1}"#
        await state.start()
        let port = try XCTUnwrap(state.port)
        XCTAssertEqual(state.address, "http://localhost:\(port)")
        XCTAssertFalse(state.hasUnappliedChanges)
        let url = "http://localhost:\(port)/bnpl-service/execute-payment/pay"
        var result = try await get(url, method: "POST")
        XCTAssertEqual(result.1, #"{"v":1}"#)

        // Taslak değişti: uygulanana kadar çalışan tanım aynı.
        state.endpoints[0].response.body = #"{"v":2}"#
        XCTAssertTrue(state.hasUnappliedChanges)
        result = try await get(url, method: "POST")
        XCTAssertEqual(result.1, #"{"v":1}"#, "uygulanmayan değişiklik sunucuya gitmez")

        state.applyChanges()
        XCTAssertFalse(state.hasUnappliedChanges)
        XCTAssertEqual(state.port, port, "port korunur")
        try await Task.sleep(for: .milliseconds(50))
        result = try await get(url, method: "POST")
        XCTAssertEqual(result.1, #"{"v":2}"#)

        // Değişiklik geri alınınca "uygulanmamış" da kalkar.
        state.endpoints[0].response.body = #"{"v":3}"#
        state.endpoints[0].response.body = #"{"v":2}"#
        XCTAssertFalse(state.hasUnappliedChanges)

        await state.stop()
        XCTAssertEqual(state.status, .stopped)
        XCTAssertFalse(state.hasUnappliedChanges, "durmuşken uygulanacak bir şey yok")
        XCTAssertNotNil(state.endpoints.first { $0.id == id }, "tanımlar kalır")
    }

    func testRequestLogIsRecordedAndCapped() async throws {
        let state = makeState()
        state.addEndpoint()
        state.endpoints[0].path = "/a"
        await state.start()
        let port = try XCTUnwrap(state.port)
        _ = try await get("http://localhost:\(port)/a?x=1")
        _ = try await get("http://localhost:\(port)/yok")
        for _ in 0..<50 where state.log.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(state.log.count, 2)
        XCTAssertEqual(state.log[0].outcome, .noEndpoint, "en yeni başta")
        XCTAssertEqual(state.log[1].outcome, .defaultResponse)
        state.clearLog()
        XCTAssertTrue(state.log.isEmpty)
    }

    func testAllPortsBusyShowsTheUsersMessage() async throws {
        let state = makeState()
        let ports = try XCTUnwrap(Mirror(reflecting: state).children.first { $0.label == "ports" }?.value as? [UInt16])
        for port in ports {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { $0.cancel() }
            let ready = expectation(description: "hazır")
            listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            listener.start(queue: .global())
            await fulfillment(of: [ready], timeout: 3)
            blockers.append(listener)
        }
        await state.start()
        guard case .failed(let message) = state.status else { return XCTFail("\(state.status)") }
        XCTAssertEqual(message, MockerState.portsInUseMessage(ports))
        XCTAssertFalse(state.isRunning)
    }

    func testPortsInUseMessageMatchesTheRequestedWording() {
        let message = MockerState.portsInUseMessage([8098, 8099, 8100])
        if L10n.language == .turkish {
            XCTAssertEqual(message, "8098, 8099 ve 8100 portları kullanımda. Mocker'ı başlatmak için bu portlardan birini boşaltın.")
        } else {
            XCTAssertEqual(message, "Ports 8098, 8099 and 8100 are in use. Free one of them to start Mocker.")
        }
    }

    func testDefinitionsPersistAcrossLaunches() async throws {
        let state = makeState()
        state.addEndpoint()
        state.endpoints[0].method = .post
        state.endpoints[0].path = "/pay"
        state.endpoints[0].scenarios = [MockScenario(name: "red", conditions: [
            MockCondition(source: .jsonBody, name: "$.amount", comparison: .equals, value: "0"),
        ])]
        state.flushPendingSave()
        let reopened = MockerState(root: root, ports: [1])
        XCTAssertEqual(reopened.endpoints, state.endpoints)
        XCTAssertEqual(reopened.selectedEndpointID, state.endpoints.first?.id)
        XCTAssertFalse(reopened.isRunning, "açılışta kendiliğinden başlamaz")
    }

    func testEditingHelpers() {
        let state = makeState()
        let first = try? XCTUnwrap(state.addEndpoint())
        XCTAssertEqual(state.endpoints[0].path, "/new")
        state.addEndpoint()
        XCTAssertEqual(state.endpoints[1].path, "/new-2", "yeni yol çakışmaz")
        state.duplicateEndpoint(state.endpoints[0].id)
        XCTAssertEqual(state.endpoints.count, 3)
        XCTAssertNotEqual(state.endpoints[1].id, first, "kopya yeni kimlik alır")
        XCTAssertFalse(state.issues.isEmpty, "kopya aynı istekleri yakalar: uyarı")
        state.deleteEndpoint(state.endpoints[1].id)
        XCTAssertTrue(state.issues.isEmpty)
        state.moveEndpoint(state.endpoints[0].id, by: 1)
        XCTAssertEqual(state.endpoints[1].id, first)
    }

    /// Boştayken sunucu iş yapmamalı (kullanıcı isteği: gereksiz CPU yok).
    func testIdleServerUsesAlmostNoCPU() async throws {
        let state = makeState()
        state.addEndpoint()
        await state.start()
        XCTAssertTrue(state.isRunning)
        try await Task.sleep(for: .milliseconds(300))
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let before = cpu()
        try await Task.sleep(for: .seconds(2))
        let used = cpu() - before
        XCTAssertLessThan(used, 0.05, "2 sn boşta \(used) sn işlemci")
    }

    func testValidationCostStaysSmallForManyEndpoints() {
        let endpoints = (0..<500).map { MockEndpoint(method: .any, path: "/svc/\($0 % 50)/{id}/item\($0)") }
        let start = ContinuousClock.now
        _ = MockValidator.issues(for: endpoints)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500), "her düzenlemede çalışıyor")
    }

    // MARK: Ekran

    private func host(_ state: MockerState) -> NSView {
        let view = NSHostingView(rootView: MockerView().environment(state).environment(AppStateHarness().state)
            .frame(width: 1100, height: 700))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return view
    }

    private func texts(_ view: NSView) -> [NSView] {
        ((view is NSTextView || view is NSTextField) ? [view] : []) + view.subviews.flatMap(texts)
    }

    func testEditorShowsEndpointWithScenario() {
        let state = makeState()
        state.addEndpoint()
        state.endpoints[0].scenarios = [MockScenario(name: "red", conditions: [MockCondition(source: .query, name: "x", comparison: .exists)])]
        let root = host(state)
        // Yol alanı, varsayılan ve senaryo response gövdesi (iki kod editörü) ve koşul alanı.
        XCTAssertGreaterThanOrEqual(texts(root).filter { $0 is NSTextView }.count, 2)
        XCTAssertTrue(texts(root).contains { ($0 as? NSTextField)?.stringValue == "/new" })
    }

    func testEmptyStateWithoutEndpoints() {
        let state = makeState()
        let root = host(state)
        XCTAssertTrue(texts(root).filter { $0 is NSTextView }.isEmpty, "endpoint yokken editör kurulmaz")
    }
}
