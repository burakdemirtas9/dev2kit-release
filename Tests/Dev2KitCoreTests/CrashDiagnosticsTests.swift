import XCTest
@testable import Dev2KitCore

/// Son çökme raporu: normal kapanış, rapor yok, rapora erişilemiyor, temiz
/// olmayan kapanış ve doğrulanmış çökme ayrı ayrı. Tüm veriler sahte ve
/// geçici dizinde; kullanıcının rapor dizinine ve workspace'ine dokunulmaz.
final class CrashDiagnosticsTests: XCTestCase {
    private var root: URL!
    private var reports: URL!
    private var data: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("crash-tests-\(UUID().uuidString)")
        reports = root.appendingPathComponent("DiagnosticReports")
        data = root.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reports.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Yardımcılar

    private let launched = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(pid: Int32 = 4242, launchedAt: Date? = nil) -> SessionRecord {
        SessionRecord(pid: pid, launchedAt: launchedAt ?? launched, appVersion: "1.0.0", build: "10", osVersion: "Version 14.0 (Build TEST)")
    }

    private func diagnostics(running: Set<Int32> = [], log: DiagnosticLog? = nil) -> CrashDiagnostics {
        CrashDiagnostics(directory: data,
                         locator: CrashReportLocator(directory: reports, processName: "testapp", bundleID: "com.example.testapp"),
                         log: log,
                         isRunningInstance: { running.contains($0) })
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 3 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter.string(from: date)
    }

    /// macOS 12+ `.ips` biçiminde sahte rapor: ilk satır metaveri, kalanı gövde.
    private func ips(pid: Int32 = 4242, launchedAt: Date? = nil, bugType: String = "309",
                     bundleID: String = "com.example.testapp", extraBody: [String: Any] = [:]) throws -> Data {
        let launch = launchedAt ?? launched
        let meta: [String: Any] = [
            "app_name": "testapp", "bundleID": bundleID, "app_version": "1.0.0", "build_version": "10",
            "bug_type": bugType, "timestamp": Self.stamp(launch.addingTimeInterval(60)),
            "os_version": "macOS 14.0 (TEST)", "incident_id": "00000000-0000-0000-0000-000000000001", "name": "testapp",
        ]
        var body: [String: Any] = [
            "pid": Int(pid), "procLaunch": Self.stamp(launch.addingTimeInterval(0.25)),
            "crashReporterKey": "SECRET-DEVICE-KEY", "bootSessionUUID": "SECRET-BOOT",
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x10"],
            "termination": ["indicator": "Segmentation fault: 11", "namespace": "SIGNAL", "code": 11],
            "asi": ["libsystem": ["Authorization: Bearer fake-token-value"]],
            "faultingThread": 1,
            "usedImages": [["name": "testapp", "path": "/Users/someone/secret/testapp"], ["name": "libswiftCore.dylib"]],
            "threads": [
                ["frames": [["imageIndex": 1, "imageOffset": 1, "symbol": "idle"]]],
                ["triggered": true, "threadState": ["x": [["value": 123456]]],
                 "frames": [["imageIndex": 0, "imageOffset": 4096, "symbol": "Crasher.run()", "symbolLocation": 12],
                            ["imageIndex": 1, "imageOffset": 8192]]],
            ],
        ]
        body.merge(extraBody) { $1 }
        var result = try JSONSerialization.data(withJSONObject: meta)
        result.append(0x0A)
        result.append(try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]))
        return result
    }

    private func writeReport(_ data: Data, name: String = "testapp-2027-01-15-100000.ips") throws {
        try data.write(to: reports.appendingPathComponent(name))
    }

    // MARK: - Senaryolar

    func testCleanShutdownLeavesNoRecord() {
        let first = diagnostics()
        XCTAssertNil(first.launch(current: session()).latest)
        first.endSession(pid: 4242)
        let status = diagnostics().launch(current: session(pid: 5000))
        XCTAssertNil(status.latest)
        XCTAssertTrue(status.reportsAccessible)
    }

    func testUncleanShutdownWithoutReportIsNotCalledACrash() {
        diagnostics().launch(current: session())
        // endSession yok: süreç zorla kapandı / elektrik kesildi.
        let status = diagnostics().launch(current: session(pid: 5000))
        XCTAssertEqual(status.latest?.kind, .uncleanShutdown)
        XCTAssertNil(status.latest?.summary)
        XCTAssertEqual(status.latest?.reportsAccessible, true)
        let text = CrashReportText.make(status.latest!, events: [], current: session(pid: 5000))
        XCTAssertTrue(text.contains(L10n.t("crash.text.uncleanTitle")))
        XCTAssertFalse(text.contains(L10n.t("crash.text.verifiedTitle")))
    }

    func testMatchingReportIsVerifiedCrash() throws {
        diagnostics().launch(current: session())
        try writeReport(try ips())
        let status = diagnostics().launch(current: session(pid: 5000))
        let latest = try XCTUnwrap(status.latest)
        XCTAssertEqual(latest.kind, .verifiedCrash)
        XCTAssertEqual(latest.summary?.headline, "EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertEqual(latest.summary?.termination, "Segmentation fault: 11")
        XCTAssertEqual(latest.summary?.frames, ["testapp  Crasher.run() + 12", "libswiftCore.dylib  0x2000"])
        XCTAssertEqual(latest.summary?.appVersion, "1.0.0")
        XCTAssertEqual(latest.summary?.fileName, "testapp-2027-01-15-100000.ips")
    }

    func testReportPrivacyAllowlist() throws {
        diagnostics().launch(current: session())
        try writeReport(try ips())
        let status = diagnostics().launch(current: session(pid: 5000))
        let text = CrashReportText.make(status.latest!, events: [], current: session(pid: 5000))
        let stored = try String(contentsOf: data.appendingPathComponent("latest-crash.json"), encoding: .utf8)
        for leaked in ["SECRET-DEVICE-KEY", "SECRET-BOOT", "fake-token-value", "Bearer", "/Users/someone", "123456"] {
            XCTAssertFalse(text.contains(leaked), leaked)
            XCTAssertFalse(stored.contains(leaked), leaked)
        }
    }

    func testReportsOfOtherSessionsAppsAndTypesAreIgnored() throws {
        diagnostics().launch(current: session())
        try writeReport(try ips(pid: 9999), name: "testapp-2027-01-15-100001.ips")
        try writeReport(try ips(launchedAt: launched.addingTimeInterval(-3600)), name: "testapp-2027-01-15-100002.ips")
        try writeReport(try ips(bundleID: "com.example.other"), name: "testapp-2027-01-15-100003.ips")
        try writeReport(try ips(bugType: "288"), name: "testapp-2027-01-15-100004.ips")
        try writeReport(try ips(), name: "otherapp-2027-01-15-100005.ips")
        try writeReport(Data("not json\n{".utf8), name: "testapp-2027-01-15-100006.ips")
        let status = diagnostics().launch(current: session(pid: 5000))
        XCTAssertEqual(status.latest?.kind, .uncleanShutdown)
    }

    func testOversizedReportIsSkipped() throws {
        diagnostics().launch(current: session())
        let padding = String(repeating: "x", count: CrashReportParser.maximumFileSize)
        try writeReport(try ips(extraBody: ["padding": padding]))
        XCTAssertEqual(diagnostics().launch(current: session(pid: 5000)).latest?.kind, .uncleanShutdown)
    }

    func testInaccessibleReportsDirectoryIsDistinctFromNoReport() throws {
        diagnostics().launch(current: session())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: reports.path)
        let status = diagnostics().launch(current: session(pid: 5000))
        XCTAssertFalse(status.reportsAccessible)
        XCTAssertEqual(status.latest?.kind, .uncleanShutdown)
        XCTAssertEqual(status.latest?.reportsAccessible, false)
        let text = CrashReportText.make(status.latest!, events: [], current: session(pid: 5000))
        XCTAssertTrue(text.contains(L10n.t("crash.unclean.noteInaccessible")))

        // Kayıt yokken de "erişilemedi" ayrı.
        let cleared = diagnostics().clear()
        XCTAssertNil(cleared.latest)
        XCTAssertFalse(cleared.reportsAccessible)
    }

    func testMissingReportsDirectoryMeansNoReport() throws {
        try FileManager.default.removeItem(at: reports)
        let status = diagnostics().launch(current: session())
        XCTAssertNil(status.latest)
        XCTAssertTrue(status.reportsAccessible)
    }

    func testRunningInstanceIsNotUnclean() {
        diagnostics().launch(current: session())
        // 4242 hâlâ çalışıyor (ikinci kopya açıldı).
        let status = diagnostics(running: [4242]).launch(current: session(pid: 5000))
        XCTAssertNil(status.latest)
        // İlk kopyanın kaydı korunur: sonra çökerse yakalanır.
        let later = diagnostics().launch(current: session(pid: 6000))
        XCTAssertEqual(later.latest?.session.pid, 4242)
    }

    func testLateReportUpgradesOnRefresh() throws {
        diagnostics().launch(current: session())
        XCTAssertEqual(diagnostics().launch(current: session(pid: 5000)).latest?.kind, .uncleanShutdown)
        // macOS raporu açılıştan sonra yazdı.
        try writeReport(try ips())
        let refreshed = diagnostics().refresh()
        XCTAssertEqual(refreshed.latest?.kind, .verifiedCrash)
        // Kalıcı: temiz kapanıp yeniden açılınca da görünür.
        diagnostics().endSession(pid: 5000)
        XCTAssertEqual(diagnostics().launch(current: session(pid: 6000)).latest?.kind, .verifiedCrash)
    }

    func testClearKeepsMacOSReport() throws {
        diagnostics().launch(current: session())
        try writeReport(try ips())
        XCTAssertEqual(diagnostics().launch(current: session(pid: 5000)).latest?.kind, .verifiedCrash)
        XCTAssertNil(diagnostics().clear().latest)
        diagnostics().endSession(pid: 5000)
        XCTAssertNil(diagnostics().launch(current: session(pid: 6000)).latest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reports.appendingPathComponent("testapp-2027-01-15-100000.ips").path))
    }

    func testNewestSessionWins() throws {
        diagnostics().launch(current: session(pid: 1, launchedAt: launched))
        diagnostics().launch(current: session(pid: 2, launchedAt: launched.addingTimeInterval(100)))
        try writeReport(try ips(pid: 1))
        let status = diagnostics().launch(current: session(pid: 3, launchedAt: launched.addingTimeInterval(200)))
        XCTAssertEqual(status.latest?.session.pid, 2)
        XCTAssertEqual(status.latest?.kind, .uncleanShutdown)
    }

    func testCorruptSessionFileIsDiscarded() throws {
        let sessions = data.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: sessions.appendingPathComponent("77.json"))
        XCTAssertNil(diagnostics().launch(current: session()).latest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("77.json").path))
    }

    func testCurrentSessionUsesKernelStartTime() {
        let current = SessionRecord.current()
        XCTAssertEqual(current.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertLessThan(current.launchedAt, Date())
        XCTAssertGreaterThan(current.launchedAt, Date().addingTimeInterval(-3600))
        XCTAssertTrue(CrashDiagnostics.isRunning(pid: current.pid, named: ProcessInfo.processInfo.processName))
        XCTAssertFalse(CrashDiagnostics.isRunning(pid: 0, named: "x"))
    }

    func testDateParsing() {
        XCTAssertNotNil(CrashReportParser.parseDate("2027-01-15 10:00:00.00 +0300"))
        XCTAssertEqual(CrashReportParser.parseDate("2027-01-15 10:00:00.5 +0000")?.timeIntervalSince1970,
                       CrashReportParser.parseDate("2027-01-15 10:00:00 +0000").map { $0.timeIntervalSince1970 + 0.5 })
        XCTAssertNil(CrashReportParser.parseDate("garbage"))
    }
}

/// Yerel tanılama günlüğü: sınırlı, yerel, serbest metin yok.
final class DiagnosticLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("diaglog-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEventsBeforeActivationAreBufferedNotWritten() {
        let log = DiagnosticLog()
        log.record(DiagnosticEvent(kind: .sessionStarted))
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        log.activate(directory: directory)
        XCTAssertEqual(log.recentEvents().map(\.kind), [.sessionStarted])
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("events.log").path)
        XCTAssertEqual((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRotationBoundsSize() {
        let log = DiagnosticLog(maximumFileSize: 1024)
        log.activate(directory: directory)
        for _ in 0..<200 { log.record(DiagnosticEvent(kind: .storageSaveFailed, error: CocoaError(.fileWriteOutOfSpace))) }
        log.flush()
        for name in ["events.log", "events.1.log"] {
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            XCTAssertLessThanOrEqual(size, 1024, name)
        }
        XCTAssertFalse(log.recentEvents(limit: 5).isEmpty)
    }

    func testRetentionDropsOldEvents() {
        let now = Date()
        let first = DiagnosticLog()
        first.activate(directory: directory, now: now.addingTimeInterval(-30 * 86400))
        first.record(DiagnosticEvent(kind: .sessionStarted, time: now.addingTimeInterval(-30 * 86400)))
        first.record(DiagnosticEvent(kind: .sessionEnded, time: now.addingTimeInterval(-60)))
        first.flush()
        let second = DiagnosticLog()
        second.activate(directory: directory, now: now)
        XCTAssertEqual(second.recentEvents().map(\.kind), [.sessionEnded])
    }

    func testOnlyErrorDomainAndCodeAreKept() throws {
        let error = NSError(domain: "NSURLErrorDomain", code: -1001,
                            userInfo: [NSLocalizedDescriptionKey: "token=fake-secret at /Users/someone/file"])
        let event = DiagnosticEvent(kind: .storageSaveFailed, error: error)
        XCTAssertEqual(event.errorDomain, "NSURLErrorDomain")
        XCTAssertEqual(event.errorCode, -1001)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fake-secret"))
        XCTAssertFalse(encoded.contains("/Users"))
        // Beklenmedik alan adı yazılmaz.
        XCTAssertNil(DiagnosticEvent(kind: .storageSaveFailed, error: NSError(domain: "user@example.test /x", code: 1)).errorDomain)
    }

    func testUnwritableDirectoryDoesNotThrowOrCrash() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let log = DiagnosticLog()
        log.activate(directory: directory)
        log.record(DiagnosticEvent(kind: .sessionStarted))
        log.flush()
        XCTAssertEqual(log.recentEvents(), [])
    }

    func testEventsAppearInReportText() {
        let record = LatestCrashRecord(kind: .uncleanShutdown,
                                       session: SessionRecord(pid: 1, launchedAt: Date(), appVersion: "1", build: "2", osVersion: "x"),
                                       summary: nil, reportsAccessible: true, detectedAt: Date())
        let events = [DiagnosticEvent(kind: .storageRecovered, detail: .restoredFromBackup),
                      DiagnosticEvent(kind: .storageSaveFailed, error: CocoaError(.fileWriteOutOfSpace))]
        let text = CrashReportText.make(record, events: events, current: record.session)
        XCTAssertTrue(text.contains("storageRecovered  restoredFromBackup"))
        XCTAssertTrue(text.contains("NSCocoaErrorDomain 640"))
    }
}
