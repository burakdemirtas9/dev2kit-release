import XCTest
@testable import Dev2KitCore

/// Donma bekçisinin kuralları (2026-10-31): 10 sn yanıtsızlık kaydedilir,
/// donma + 2 GB kapatır, uyku/kilit/görünmez pencere hiçbir şey yaptırmaz.
final class HangWatchdogTests: XCTestCase {
    /// Açılış payı bitmiş, `t` anında kurulmuş bekçi.
    private func policy(at t: Double = 0) -> HangWatchdogPolicy {
        var policy = HangWatchdogPolicy(startedAt: t - 100)
        XCTAssertEqual(policy.evaluate(now: t, lastHeartbeat: t, memoryMB: 100, suppressed: false), [])
        return policy
    }

    // MARK: - Donma

    func testShortStallsAreNotHangs() {
        var p = policy()
        XCTAssertEqual(p.evaluate(now: 9.9, lastHeartbeat: 0, memoryMB: 300, suppressed: false), [])
    }

    func testHangIsRecordedOnceAndRecoveryCarriesItsDuration() {
        var p = policy()
        XCTAssertEqual(p.evaluate(now: 10, lastHeartbeat: 0, memoryMB: 300, suppressed: false), [.recordHang(stallSeconds: 10)])
        XCTAssertEqual(p.evaluate(now: 11, lastHeartbeat: 0, memoryMB: 300, suppressed: false), [], "aynı donma bir kez")
        XCTAssertEqual(p.evaluate(now: 25, lastHeartbeat: 0, memoryMB: 300, suppressed: false), [])
        XCTAssertEqual(p.evaluate(now: 26, lastHeartbeat: 25.5, memoryMB: 300, suppressed: false), [.recordRecovered(stallSeconds: 25)])
        // Yeni donma yeniden kaydedilir.
        XCTAssertEqual(p.evaluate(now: 40, lastHeartbeat: 26, memoryMB: 300, suppressed: false), [.recordHang(stallSeconds: 14)])
    }

    // MARK: - Kapatma: donma VE bellek

    func testHangWithMemoryOverLimitTerminates() {
        var p = policy()
        XCTAssertEqual(p.evaluate(now: 10, lastHeartbeat: 0, memoryMB: 2_048, suppressed: false),
                       [.recordHang(stallSeconds: 10), .terminate(stallSeconds: 10)])
        XCTAssertEqual(p.evaluate(now: 11, lastHeartbeat: 0, memoryMB: 3_000, suppressed: false), [], "bir kez kapatılır")
    }

    func testMemoryGrowingDuringHangTerminatesThen() {
        var p = policy()
        XCTAssertEqual(p.evaluate(now: 10, lastHeartbeat: 0, memoryMB: 900, suppressed: false), [.recordHang(stallSeconds: 10)])
        XCTAssertEqual(p.evaluate(now: 30, lastHeartbeat: 0, memoryMB: 1_900, suppressed: false), [])
        XCTAssertEqual(p.evaluate(now: 45, lastHeartbeat: 0, memoryMB: 2_100, suppressed: false), [.terminate(stallSeconds: 45)])
    }

    func testHighMemoryWhileResponsiveIsRecordedOnceAfterItLasts() {
        var p = policy()
        XCTAssertEqual(p.evaluate(now: 1, lastHeartbeat: 1, memoryMB: 2_500, suppressed: false), [], "anlık sıçrama değil")
        XCTAssertEqual(p.evaluate(now: 10, lastHeartbeat: 10, memoryMB: 2_500, suppressed: false), [])
        XCTAssertEqual(p.evaluate(now: 11, lastHeartbeat: 11, memoryMB: 2_600, suppressed: false), [.recordHighMemory], "10 sn üstte, yanıt veriyor")
        XCTAssertEqual(p.evaluate(now: 30, lastHeartbeat: 30, memoryMB: 2_600, suppressed: false), [], "kapatma yok, tekrar yazılmaz")
        // Yeniden kurulması için eşiğin (1,5 GB) altına inmesi gerekir.
        XCTAssertEqual(p.evaluate(now: 31, lastHeartbeat: 31, memoryMB: 1_800, suppressed: false), [])
        XCTAssertEqual(p.evaluate(now: 45, lastHeartbeat: 45, memoryMB: 2_100, suppressed: false), [])
        XCTAssertEqual(p.evaluate(now: 46, lastHeartbeat: 46, memoryMB: 1_000, suppressed: false), [])
        XCTAssertEqual(p.evaluate(now: 47, lastHeartbeat: 47, memoryMB: 2_100, suppressed: false), [])
        XCTAssertEqual(p.evaluate(now: 57, lastHeartbeat: 57, memoryMB: 2_100, suppressed: false), [.recordHighMemory])
    }

    /// Kaçak donmada bellek uyarısı ayrıca yazılmaz: donma ve kapatma yeter.
    func testRunawayHangDoesNotAlsoRecordHighMemory() {
        var p = policy()
        var all: [HangWatchdogPolicy.Action] = []
        for t in stride(from: 1.0, through: 10.0, by: 1.0) {
            all += p.evaluate(now: t, lastHeartbeat: 0, memoryMB: 3_000, suppressed: false)
        }
        XCTAssertEqual(all, [.recordHang(stallSeconds: 10), .terminate(stallSeconds: 10)])
    }

    // MARK: - Uyku, kilit, görünmez pencere

    func testNothingHappensWhileSuppressed() {
        var p = policy()
        XCTAssertEqual(p.evaluate(now: 60, lastHeartbeat: 0, memoryMB: 5_000, suppressed: true), [])
        XCTAssertEqual(p.evaluate(now: 600, lastHeartbeat: 0, memoryMB: 5_000, suppressed: true), [])
    }

    func testAfterWakeThereIsAGracePeriodAndStallCountsFromWake() {
        var p = policy()
        _ = p.evaluate(now: 5, lastHeartbeat: 5, memoryMB: 300, suppressed: true)   // uykuya/kilide geçti
        // Uyanış: kalp atışı uykudan önceki; uyku boyunca geçen süre sayılmaz.
        XCTAssertEqual(p.evaluate(now: 100, lastHeartbeat: 5, memoryMB: 300, suppressed: false), [])
        XCTAssertEqual(p.evaluate(now: 125, lastHeartbeat: 5, memoryMB: 300, suppressed: false), [], "uyanış payı (30 sn)")
        // Pay bitti; ana iş parçacığı uyanıştan beri yanıt vermiyorsa: uyanıştan sayılır.
        XCTAssertEqual(p.evaluate(now: 130, lastHeartbeat: 5, memoryMB: 300, suppressed: false), [.recordHang(stallSeconds: 30)])
    }

    func testHangInProgressIsDroppedWhenSuppressed() {
        var p = policy()
        XCTAssertEqual(p.evaluate(now: 10, lastHeartbeat: 0, memoryMB: 300, suppressed: false), [.recordHang(stallSeconds: 10)])
        XCTAssertEqual(p.evaluate(now: 11, lastHeartbeat: 0, memoryMB: 3_000, suppressed: true), [], "kilitliyken kapatılmaz")
        // Kilit açıldı, ana iş parçacığı yanıt veriyor: toparlanma yazılmaz (donma düşürüldü).
        XCTAssertEqual(p.evaluate(now: 50, lastHeartbeat: 50, memoryMB: 300, suppressed: false), [])
    }

    func testLaunchHasAGracePeriod() {
        var p = HangWatchdogPolicy(startedAt: 0)
        XCTAssertEqual(p.evaluate(now: 29, lastHeartbeat: 0, memoryMB: 300, suppressed: false), [])
        XCTAssertEqual(p.evaluate(now: 30, lastHeartbeat: 0, memoryMB: 300, suppressed: false), [.recordHang(stallSeconds: 30)])
    }

    // MARK: - Boyut aralıkları ve bağlam

    func testSizeBuckets() {
        XCTAssertEqual(DiagnosticSize(0), .zero)
        XCTAssertEqual(DiagnosticSize(1), .upTo10)
        XCTAssertEqual(DiagnosticSize(10), .upTo10)
        XCTAssertEqual(DiagnosticSize(11), .upTo100)
        XCTAssertEqual(DiagnosticSize(8_192), .upTo10K)
        XCTAssertEqual(DiagnosticSize(1_000_000), .upTo1M)
        XCTAssertEqual(DiagnosticSize(10_000_001), .over10M)
    }

    func testHeaderFiguresCountVariablesAndLongestValue() {
        let figures = DiagnosticContext.headerFigures([
            KeyValueEntry(key: "Authorization", value: "Bearer {{token}}"),
            KeyValueEntry(key: "X", value: String(repeating: "a", count: 500) + "{{a}}{{b}}"),
            KeyValueEntry(key: "Y", value: ""),
        ])
        XCTAssertEqual(figures.count, .upTo10)
        XCTAssertEqual(figures.longest, .upTo1K)
        XCTAssertEqual(figures.variables, .upTo10)
        XCTAssertEqual(DiagnosticContext.headerFigures([]).variables, .zero)
    }

    /// Gizlilik: kodlanan olayda yalnızca izinli anahtarlar ve hiçbir değer metni.
    func testEncodedHangEventHasOnlyAllowedKeys() throws {
        let event = DiagnosticEvent(kind: .watchdogTerminated, time: Date(timeIntervalSince1970: 1_800_000_000), context: DiagnosticContext(
            screen: .apiClientHeaders, headerCount: .upTo100, longestHeaderValue: .upTo100K,
            headerVariables: .upTo1K, bodySize: .zero, responseSize: .upTo1M, responseKind: .json,
            memoryMB: 2_310, stallSeconds: 12
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: DiagnosticLog.encoder.encode(event)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["time", "kind", "context"])
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        XCTAssertEqual(Set(context.keys), [
            "screen", "headerCount", "longestHeaderValue", "headerVariables", "bodySize",
            "responseSize", "responseKind", "memoryMB", "stallSeconds",
        ])
        XCTAssertEqual(try DiagnosticLog.decoder.decode(DiagnosticEvent.self, from: DiagnosticLog.encoder.encode(event)), event)
    }

    /// Eski sürümün yazdığı satır (bağlamsız) okunmaya devam eder.
    func testOldEventLinesStillDecode() throws {
        let line = #"{"kind":"sessionStarted","time":"2026-10-30T10:00:00Z"}"#
        let event = try DiagnosticLog.decoder.decode(DiagnosticEvent.self, from: Data(line.utf8))
        XCTAssertEqual(event.kind, .sessionStarted)
        XCTAssertNil(event.context)
    }

    func testReportTextShowsContextSummary() {
        let event = DiagnosticEvent(kind: .mainThreadHang, time: Date(timeIntervalSince1970: 0),
                                    context: DiagnosticContext(screen: .apiClientHeaders, memoryMB: 2_300, stallSeconds: 10))
        XCTAssertEqual(CrashReportText.describe(event),
                       "1970-01-01T00:00:00Z  mainThreadHang  screen=apiClientHeaders memory=2300MB stall=10s")
    }

    func testMemoryIsRoundedForTheLog() {
        XCTAssertEqual(ProcessMemory.rounded(2_317), 2_310)
        XCTAssertNotNil(ProcessMemory.footprintMB())
    }

    // MARK: - "Bekçi kapattı" işareti

    func testTerminationMarkerIsReadOnce() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("watchdog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(WatchdogTermination.consume(in: directory))
        let record = WatchdogTermination(time: Date(timeIntervalSince1970: 1_000), stallSeconds: 14, memoryMB: 2_300)
        WatchdogTermination.write(record, in: directory)
        XCTAssertEqual(WatchdogTermination.consume(in: directory), record)
        XCTAssertNil(WatchdogTermination.consume(in: directory), "bir kez gösterilir")
    }
}
