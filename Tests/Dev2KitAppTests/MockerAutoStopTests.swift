import AppKit
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Mocker kaynak korumak için kendini durdurur (kullanıcı isteği, 2026-11-07):
/// Mac uykuya geçince, ekran kilitlenince (oturum değişimi dahil) ya da
/// 10 dakika hiç istek gelmeyince. Nedeni ekranda söylenir.
@MainActor
final class MockerAutoStopTests: XCTestCase {
    private var root: URL!
    private var state: MockerState?

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mocker-autostop-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        await state?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeState(idle: Double = 600) -> MockerState {
        let base = UInt16.random(in: 20_000...39_000)
        let state = MockerState(root: root, ports: [base, base + 1, base + 2], idleStopSeconds: idle)
        state.addEndpoint()
        self.state = state
        return state
    }

    private func wait(until condition: () -> Bool, timeout: Double = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
    }

    func testStopsAfterIdleTimeAndSaysWhy() async throws {
        let state = makeState(idle: 0.5)
        await state.start()
        XCTAssertTrue(state.isRunning)
        await wait(until: { !state.isRunning })
        XCTAssertEqual(state.status, .stopped)
        XCTAssertEqual(state.autoStopNotice, MockerState.autoStopMessage(.idle, idleMinutes: 0))
        XCTAssertEqual(state.modeIndicator, .hidden)
    }

    func testRequestsKeepItRunning() async throws {
        let state = makeState(idle: 0.6)
        await state.start()
        let port = try XCTUnwrap(state.port)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for _ in 0..<6 {
            _ = try await session.data(from: URL(string: "http://localhost:\(port)/new")!)
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertTrue(state.isRunning, "her istek süreyi yeniler (1,8 sn > 0,6 sn)")
        XCTAssertNil(state.autoStopNotice)
    }

    func testApplyRenewsTheIdleTime() async throws {
        let state = makeState(idle: 0.6)
        await state.start()
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(300))
            state.endpoints[0].response.status = state.endpoints[0].response.status == 200 ? 201 : 200
            state.applyChanges()
        }
        XCTAssertTrue(state.isRunning, "Uygula da kullanıcı etkinliği")
    }

    func testStopsWhenTheMacSleeps() async throws {
        let state = makeState()
        await state.start()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await wait(until: { !state.isRunning })
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.autoStopNotice, MockerState.autoStopMessage(.sleep, idleMinutes: 10))
    }

    func testStopsWhenTheSessionIsSwitchedAway() async throws {
        let state = makeState()
        await state.start()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        await wait(until: { !state.isRunning })
        XCTAssertEqual(state.autoStopNotice, MockerState.autoStopMessage(.locked, idleMinutes: 10))
    }

    /// Ekran kilidi sistem geneline yayılan bildirim: testte gönderilmez
    /// (açık uygulamaları etkilerdi). Doğru kaynağı dinlediği doğrulanır.
    func testScreenLockIsObservedFromTheSystemNotification() {
        XCTAssertEqual(SystemPresenceEvent.screenLocked.notificationName.rawValue, "com.apple.screenIsLocked")
        XCTAssertTrue(SystemPresenceEvent.screenLocked.center === DistributedNotificationCenter.default())
        XCTAssertTrue(SystemPresenceEvent.willSleep.center === NSWorkspace.shared.notificationCenter)
    }

    func testWakeAndUnlockDoNotStopAndManualStopHasNoNotice() async throws {
        let state = makeState()
        await state.start()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(state.isRunning, "uyanma durdurmaz")
        await state.stop()
        XCTAssertNil(state.autoStopNotice, "elle durdurmada not yok")
    }

    func testStartClearsTheNoticeAndStoppedStateIgnoresEvents() async throws {
        let state = makeState()
        await state.start()
        await state.autoStop(.locked)
        XCTAssertNotNil(state.autoStopNotice)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.autoStopNotice, MockerState.autoStopMessage(.locked, idleMinutes: 10), "durmuşken dinleme yok")
        await state.start()
        XCTAssertNil(state.autoStopNotice)
        XCTAssertTrue(state.isRunning)
    }
}
