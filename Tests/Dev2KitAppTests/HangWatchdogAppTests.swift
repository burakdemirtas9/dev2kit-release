import AppKit
import Darwin
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Donma bekçisi uçtan uca (2026-10-31): gerçek bekçi iş parçacığı, düşük
/// eşikler; ana iş parçacığı test içinde bilerek kilitlenir. Kapatma adımı
/// enjekte edilir (süreç öldürülmez).
@MainActor
final class HangWatchdogAppTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var terminatedThread: pthread_t?
        var terminateCalls = 0
        var memoryMB = 300
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("watchdog-app-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeWatchdog(log: DiagnosticLog, box: Box) -> HangWatchdog {
        var thresholds = HangWatchdogPolicy.Thresholds()
        thresholds.hangSeconds = 1
        thresholds.graceSeconds = 0
        var configuration = HangWatchdog.Configuration(directory: directory)
        configuration.thresholds = thresholds
        configuration.interval = 0.1
        configuration.memoryMB = {
            box.lock.lock()
            defer { box.lock.unlock() }
            return box.memoryMB
        }
        configuration.log = log
        configuration.terminate = { thread in
            box.lock.lock()
            box.terminatedThread = thread
            box.terminateCalls += 1
            box.lock.unlock()
        }
        return HangWatchdog(configuration: configuration)
    }

    private func activatedLog() -> DiagnosticLog {
        let log = DiagnosticLog()
        log.activate(directory: directory)
        return log
    }

    private func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testHangIsRecordedWithContextAndRecoveryWithoutTermination() {
        let log = activatedLog()
        let box = Box()
        let watchdog = makeWatchdog(log: log, box: box)
        watchdog.start { DiagnosticContext(screen: .apiClientHeaders, headerCount: .upTo100) }
        defer { watchdog.stop() }
        pump(0.4)   // ilk yoklama işlensin: bağlam alınsın

        Thread.sleep(forTimeInterval: 2.5)   // ana iş parçacığı "donuyor"
        pump(0.6)                             // yeniden yanıt veriyor
        log.flush()

        let events = log.recentEvents()
        let hang = events.first { $0.kind == .mainThreadHang }
        XCTAssertNotNil(hang, "donma kaydedilir")
        XCTAssertEqual(hang?.context?.screen, .apiClientHeaders, "son anlık durumla")
        XCTAssertEqual(hang?.context?.headerCount, .upTo100)
        XCTAssertEqual(hang?.context?.memoryMB, 300)
        XCTAssertGreaterThanOrEqual(hang?.context?.stallSeconds ?? 0, 1)
        let recovered = events.first { $0.kind == .mainThreadRecovered }
        XCTAssertNotNil(recovered, "donma bitince süresiyle yazılır")
        XCTAssertGreaterThanOrEqual(recovered?.context?.stallSeconds ?? 0, 2)
        XCTAssertEqual(box.terminateCalls, 0, "bellek sınırın altında: kapatılmaz")
        XCTAssertNil(WatchdogTermination.consume(in: directory))
    }

    func testRunawayHangTerminatesTargetingTheMainThread() {
        let log = activatedLog()
        let box = Box()
        let watchdog = makeWatchdog(log: log, box: box)
        watchdog.start { DiagnosticContext(screen: .apiClientBody) }
        defer { watchdog.stop() }
        pump(0.4)
        let main = pthread_self()

        // Donma başlıyor, bellek donma sırasında büyüyor (kullanıcının gördüğü tablo).
        box.lock.lock(); box.memoryMB = 3_000; box.lock.unlock()
        Thread.sleep(forTimeInterval: 2.0)
        pump(0.3)
        log.flush()

        box.lock.lock()
        let calls = box.terminateCalls
        let thread = box.terminatedThread
        box.lock.unlock()
        XCTAssertEqual(calls, 1, "kaçak durumda bir kez kapatılır")
        XCTAssertTrue(thread.map { pthread_equal($0, main) != 0 } ?? false, "sinyal ANA iş parçacığına: rapor donan yığını gösterir")
        let terminated = log.recentEvents().first { $0.kind == .watchdogTerminated }
        XCTAssertEqual(terminated?.context?.screen, .apiClientBody)
        XCTAssertEqual(terminated?.context?.memoryMB, 3_000)
        let marker = WatchdogTermination.consume(in: directory)
        XCTAssertEqual(marker?.memoryMB, 3_000)
        XCTAssertGreaterThanOrEqual(marker?.stallSeconds ?? 0, 1)
        XCTAssertFalse(log.recentEvents().contains { $0.kind == .memoryHigh }, "donmadayken ayrıca bellek uyarısı yazılmaz")
    }

    // MARK: - Anlık durum ve açılış bildirimi

    func testDiagnosticContextDescribesScreenAndSizesWithoutContent() throws {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let state = harness.state
        state.mode = .apiClient   // önceki bir test Workbench'te bırakmış olabilir
        let request = harness.addRequest(named: "gizli-istek-adi", url: "https://secret.example.test/path")
        let index = state.workspace.collections[0].requests.firstIndex { $0.id == request.id }!
        state.workspace.collections[0].requests[index].headers = [
            KeyValueEntry(key: "Authorization", value: "Bearer {{token}}"),
            KeyValueEntry(key: "Cookie", value: String(repeating: "c", count: 20_000)),
        ]
        state.workspace.collections[0].requests[index].body = .raw(content: String(repeating: "x", count: 500), contentType: "text/plain")
        state.showRequest(request.id)
        state.editorTab = .headers

        let context = state.diagnosticContext
        XCTAssertEqual(context.screen, .apiClientHeaders)
        XCTAssertEqual(context.headerCount, .upTo10)
        XCTAssertEqual(context.longestHeaderValue, .upTo100K)
        XCTAssertEqual(context.headerVariables, .upTo10)
        XCTAssertEqual(context.bodySize, .upTo1K)
        XCTAssertNil(context.responseSize, "yanıt yok")

        let encoded = String(decoding: try DiagnosticLog.encoder.encode(DiagnosticEvent(kind: .mainThreadHang, context: context)), as: UTF8.self)
        for secret in ["gizli-istek-adi", "secret.example.test", "Authorization", "Bearer", "token", "Cookie"] {
            XCTAssertFalse(encoded.contains(secret), "günlüğe içerik girmez: \(secret)")
        }

        state.mode = .workbench
        XCTAssertEqual(state.diagnosticContext, DiagnosticContext(screen: .workbench))
        state.mode = .apiClient
    }

    func testWatchdogTerminationBecomesAStartupWarning() {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let state = harness.state
        state.startupMessage = nil
        state.noteWatchdogTermination(WatchdogTermination(time: Date(), stallSeconds: 14, memoryMB: 2_355))
        XCTAssertEqual(state.startupMessage?.kind, .warning)
        XCTAssertEqual(state.startupMessage?.title, L10n.t("watchdog.terminated.title"))
        XCTAssertTrue(state.startupMessage?.message?.contains("2.3") ?? false, "bellek GB olarak")

        // Başka bir açılış mesajı varsa onu ezmez, altına eklenir.
        state.startupMessage = ResultMessage(kind: .info, title: "önceki")
        state.noteWatchdogTermination(WatchdogTermination(time: Date(), stallSeconds: 14, memoryMB: 2_355))
        XCTAssertEqual(state.startupMessage?.title, "önceki")
        XCTAssertEqual(state.startupMessage?.lines.count, 1)
    }
}
