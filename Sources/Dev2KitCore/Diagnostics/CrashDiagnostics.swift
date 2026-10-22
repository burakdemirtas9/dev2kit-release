import Darwin
import Foundation

/// Bir uygulama oturumunun kaydı. Açılışta yazılır, temiz kapanışta silinir;
/// sonraki açılışta duruyorsa oturum düzgün kapanmamıştır.
public struct SessionRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    /// Sürecin başlatıldığı an (çökme raporundaki `procLaunch` ile eşleşir).
    public var launchedAt: Date
    public var appVersion: String
    public var build: String
    public var osVersion: String

    public init(pid: Int32, launchedAt: Date, appVersion: String, build: String, osVersion: String) {
        self.pid = pid
        self.launchedAt = launchedAt
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
    }

    /// Çalışan sürecin kaydı. Başlatılma zamanı çekirdekten okunur
    /// (`sysctl`); okunamazsa şimdiki zaman.
    public static func current(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> SessionRecord {
        let pid = processInfo.processIdentifier
        return SessionRecord(
            pid: pid,
            launchedAt: processStartDate(pid: pid) ?? Date(),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
            osVersion: processInfo.operatingSystemVersionString
        )
    }

    static func processStartDate(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}

/// Son beklenmedik kapanışın kaydı (uygulamanın kendi dizininde saklanır;
/// macOS raporu silinse de görünür kalır).
public struct LatestCrashRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// macOS'un çökme raporu bu oturumla eşleşti.
        case verifiedCrash
        /// Oturum temiz kapanmadı, rapor bulunamadı: zorla kapatma, elektrik
        /// kesintisi, donma ya da raporu okunamayan bir çökme olabilir.
        /// Çökme KANITI değildir.
        case uncleanShutdown
    }

    public var kind: Kind
    public var session: SessionRecord
    public var summary: CrashSummary?
    /// Tespit sırasında macOS rapor dizini okunabildi mi.
    public var reportsAccessible: Bool
    public var detectedAt: Date
}

/// Contact panosundaki "Son çökme raporu" bölümünün durumu.
public struct CrashReportStatus: Equatable, Sendable {
    public var latest: LatestCrashRecord?
    /// macOS çökme raporları dizini okunabiliyor mu.
    public var reportsAccessible: Bool

    public init(latest: LatestCrashRecord?, reportsAccessible: Bool) {
        self.latest = latest
        self.reportsAccessible = reportsAccessible
    }
}

/// Oturum kayıtları ve son çökme kaydı.
///
/// Çökme anında HİÇBİR şey çalışmaz (sinyal yakalayıcı yok): sinyal
/// işleyicisinde dosya yazmak, bellek ayırmak ya da Swift kodu çalıştırmak
/// güvenli değil (`man sigaction`) ve macOS'un kendi raporunu bozabilir. Her
/// şey sonraki açılışta, arka planda toplanır.
///
/// Dosyalar: `diagnostics/sessions/<pid>.json` (oturum başına; aynı anda iki
/// kopya çalışırsa birbirinin kaydını ezmez), `diagnostics/latest-crash.json`.
/// Bütün yöntemler disk işi yapar: ana iş parçacığında çağrılmaz.
public final class CrashDiagnostics: @unchecked Sendable {
    public let directory: URL
    let locator: CrashReportLocator
    /// Bir pid'in hâlâ bu uygulamanın çalışan bir kopyası olup olmadığı.
    let isRunningInstance: @Sendable (Int32) -> Bool
    let log: DiagnosticLog?
    private let lock = NSLock()

    public init(directory: URL, locator: CrashReportLocator, log: DiagnosticLog? = nil,
                isRunningInstance: @escaping @Sendable (Int32) -> Bool) {
        self.directory = directory
        self.locator = locator
        self.log = log
        self.isRunningInstance = isRunningInstance
    }

    var sessionsDirectory: URL { directory.appendingPathComponent("sessions", isDirectory: true) }
    var latestURL: URL { directory.appendingPathComponent("latest-crash.json") }

    /// Açılış: önceki oturumların kayıtlarını değerlendirir, bu oturumun
    /// kaydını yazar, panonun durumunu döner.
    @discardableResult
    public func launch(current: SessionRecord, now: Date = Date()) -> CrashReportStatus {
        lock.lock(); defer { lock.unlock() }
        var latest = readLatest()
        var accessible = true
        for previous in staleSessions(excluding: current.pid) {
            let result = locator.find(for: previous.record)
            let record: LatestCrashRecord
            switch result {
            case .found(let summary):
                record = LatestCrashRecord(kind: .verifiedCrash, session: previous.record, summary: summary,
                                           reportsAccessible: true, detectedAt: now)
                log?.record(.init(kind: .crashReportFound, time: now))
            case .notFound, .inaccessible:
                if result == .inaccessible { accessible = false }
                record = LatestCrashRecord(kind: .uncleanShutdown, session: previous.record, summary: nil,
                                           reportsAccessible: result != .inaccessible, detectedAt: now)
                log?.record(.init(kind: .previousSessionUnclean, time: now))
            }
            if latest == nil || record.session.launchedAt >= latest!.session.launchedAt { latest = record }
            try? FileManager.default.removeItem(at: previous.url)
        }
        if let latest { try? write(latest) }
        try? writeSession(current)
        if accessible { accessible = locator.isAccessible() }
        return CrashReportStatus(latest: latest, reportsAccessible: accessible)
    }

    /// Panoyu açarken: rapor geç yazıldıysa (macOS raporu çökmeden birkaç
    /// saniye sonra yazabiliyor) "temiz olmayan kapanış" kaydını doğrulanmış
    /// çökmeye yükseltir.
    public func refresh() -> CrashReportStatus {
        lock.lock(); defer { lock.unlock() }
        var latest = readLatest()
        let result: CrashReportLocator.Result? = latest?.kind == .uncleanShutdown ? locator.find(for: latest!.session) : nil
        if case .found(let summary) = result, var record = latest {
            record.kind = .verifiedCrash
            record.summary = summary
            record.reportsAccessible = true
            try? write(record)
            latest = record
            log?.record(.init(kind: .crashReportFound))
        }
        let accessible = result == .inaccessible ? false : locator.isAccessible()
        return CrashReportStatus(latest: latest, reportsAccessible: accessible)
    }

    /// Temiz kapanış: bu oturumun kaydı silinir.
    public func endSession(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("\(pid).json"))
    }

    /// "Temizle": yalnızca uygulamanın kendi kaydı silinir; macOS'un `.ips`
    /// dosyasına dokunulmaz (kullanıcı kararı, 2026-10-22).
    public func clear() -> CrashReportStatus {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: latestURL)
        return CrashReportStatus(latest: nil, reportsAccessible: locator.isAccessible())
    }

    // MARK: - Dosyalar

    private func staleSessions(excluding pid: Int32) -> [(url: URL, record: SessionRecord)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let url = sessionsDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? Self.decoder.decode(SessionRecord.self, from: data) else {
                // Okunamayan kayıt değerlendirilemez; birikmesin.
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            // Aynı anda çalışan başka bir kopya: kapanmamış, çökmemiş.
            guard record.pid != pid, !isRunningInstance(record.pid) else { return nil }
            return (url, record)
        }
    }

    private func readLatest() -> LatestCrashRecord? {
        guard let data = try? Data(contentsOf: latestURL) else { return nil }
        return try? Self.decoder.decode(LatestCrashRecord.self, from: data)
    }

    private func write(_ record: LatestCrashRecord) throws {
        try AtomicFile.write(try Self.encoder.encode(record), to: latestURL)
    }

    private func writeSession(_ record: SessionRecord) throws {
        try AtomicFile.write(try Self.encoder.encode(record),
                             to: sessionsDirectory.appendingPathComponent("\(record.pid).json"))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public extension CrashDiagnostics {
    /// Uygulamanın kullandığı örnek: veri dizininde `diagnostics/`, bu
    /// uygulamanın adı ve paket kimliğiyle.
    static func live(dataDirectory: URL = AppPaths.supportDirectory, log: DiagnosticLog?) -> CrashDiagnostics {
        let processName = ProcessInfo.processInfo.processName
        return CrashDiagnostics(
            directory: dataDirectory.appendingPathComponent("diagnostics", isDirectory: true),
            locator: CrashReportLocator(processName: processName, bundleID: Bundle.main.bundleIdentifier),
            log: log,
            isRunningInstance: { pid in Self.isRunning(pid: pid, named: processName) }
        )
    }

    /// pid yaşıyor VE aynı adlı yürütülebilir dosya (pid yeniden kullanılmış
    /// olabilir; başka bir süreç "çalışan kopya" sayılmasın).
    static func isRunning(pid: Int32, named name: String) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        // p_comm 16 karaktere kırpılır.
        return !command.isEmpty && name.hasPrefix(command)
    }
}
