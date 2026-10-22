import Foundation

/// macOS'un yazdığı çökme raporunun (`.ips`) paylaşılabilir özeti.
///
/// Biçim (Apple, "Interpreting the JSON format of a crash report", macOS 12+):
/// ilk satır metaveri nesnesi; `bug_type == "309"` ise geri kalan metin
/// rapor nesnesi.
///
/// Özet bir İZİN LİSTESİ: yalnızca aşağıdaki alanlar alınır. Rapordaki cihazı
/// tanımlayan anahtarlar (`crashReporterKey`, `bootSessionUUID`,
/// `sleepWakeUUID`), yazmaçlar, bellek bölgeleri, yüklü kütüphanelerin yolları
/// ve serbest metin (`asi`, uygulamaya özgü bilgi) hiç okunmaz.
public struct CrashSummary: Codable, Equatable, Sendable {
    /// Raporun kimliği (`incident_id`); tekrar bulunanı ayırt etmek için.
    public var incidentID: String
    public var crashedAt: Date?
    public var appVersion: String?
    public var build: String?
    public var osVersion: String?
    /// "EXC_BAD_ACCESS", "EXC_BREAKPOINT".
    public var exceptionType: String?
    /// "SIGSEGV", "SIGTRAP".
    public var signal: String?
    /// "KERN_INVALID_ADDRESS at 0x…"
    public var exceptionSubtype: String?
    /// "Segmentation fault: 11"
    public var termination: String?
    /// Çöken iş parçacığının en üstteki çerçeveleri: "dev2kit  sembol + 12".
    public var frames: [String]
    /// Rapor dosyasının adı (yol değil).
    public var fileName: String

    /// Ekranda tek satır: "EXC_BAD_ACCESS (SIGSEGV)".
    public var headline: String {
        switch (exceptionType, signal) {
        case let (type?, signal?): "\(type) (\(signal))"
        case let (type?, nil): type
        case let (nil, signal?): signal
        default: termination ?? "—"
        }
    }
}

/// `.ips` dosyasını okur ve bir oturumla eşleştirir.
public enum CrashReportParser {
    /// Bundan büyük dosya okunmaz (normal rapor 20–200 KB).
    public static let maximumFileSize = 2 * 1024 * 1024
    /// Özete alınan çerçeve sayısı.
    public static let frameLimit = 8
    /// Uzun sembol adları kırpılır.
    static let fieldLimit = 200

    /// Raporun metaverisi (ilk satır).
    struct Metadata {
        var bugType: String?
        var bundleID: String?
        var appName: String?
        var appVersion: String?
        var build: String?
        var timestamp: Date?
        var osVersion: String?
        var incidentID: String?
    }

    static func metadata(from line: Data) -> Metadata? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return Metadata(
            bugType: object["bug_type"] as? String,
            bundleID: object["bundleID"] as? String,
            appName: object["app_name"] as? String,
            appVersion: object["app_version"] as? String,
            build: object["build_version"] as? String,
            timestamp: (object["timestamp"] as? String).flatMap(parseDate),
            osVersion: object["os_version"] as? String,
            incidentID: object["incident_id"] as? String
        )
    }

    /// Dosya bu oturumun çökme raporuysa özetini döner; değilse `nil`.
    ///
    /// Eşleşme: metaveride `bug_type` 309 ve paket kimliği, gövdede süreç
    /// kimliği (`pid`) aynı ve başlatılma zamanı (`procLaunch`) oturumunkine
    /// birkaç saniye yakın. Yalnızca pid yetmez: pid'ler yeniden kullanılır.
    public static func summary(of data: Data, fileName: String, matching session: SessionRecord,
                               bundleID: String?) -> CrashSummary? {
        guard data.count <= maximumFileSize,
              let newline = data.firstIndex(of: 0x0A),
              let meta = metadata(from: data[data.startIndex..<newline]),
              meta.bugType == "309",
              bundleID == nil || meta.bundleID == bundleID,
              let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        else { return nil }

        guard let pid = (body["pid"] as? NSNumber)?.int32Value, pid == session.pid else { return nil }
        if let launched = (body["procLaunch"] as? String).flatMap(parseDate) {
            guard abs(launched.timeIntervalSince(session.launchedAt)) <= launchTolerance else { return nil }
        } else if let crashed = meta.timestamp {
            guard crashed >= session.launchedAt.addingTimeInterval(-launchTolerance) else { return nil }
        } else {
            return nil
        }

        let exception = body["exception"] as? [String: Any]
        let termination = body["termination"] as? [String: Any]
        return CrashSummary(
            incidentID: clip(meta.incidentID) ?? fileName,
            crashedAt: meta.timestamp,
            appVersion: clip(meta.appVersion),
            build: clip(meta.build),
            osVersion: clip(meta.osVersion),
            exceptionType: clip(exception?["type"] as? String),
            signal: clip(exception?["signal"] as? String),
            exceptionSubtype: clip(exception?["subtype"] as? String),
            termination: clip(termination?["indicator"] as? String),
            frames: frames(in: body),
            fileName: fileName
        )
    }

    /// `procLaunch` ile oturumun kendi kaydettiği zaman arasındaki fark
    /// (uygulama başlatılması ile kaydın yazılması arasında geçen süre).
    static let launchTolerance: TimeInterval = 30

    /// Çöken iş parçacığının çerçeveleri: görüntü adı + sembol + uzaklık.
    /// Görüntünün YOLU alınmaz, yalnızca adı.
    static func frames(in body: [String: Any]) -> [String] {
        guard let threads = body["threads"] as? [[String: Any]] else { return [] }
        let index = (body["faultingThread"] as? Int) ?? threads.firstIndex { ($0["triggered"] as? Bool) == true } ?? 0
        guard threads.indices.contains(index), let frames = threads[index]["frames"] as? [[String: Any]] else { return [] }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        return frames.prefix(frameLimit).map { frame in
            let imageIndex = frame["imageIndex"] as? Int
            let image = imageIndex.flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "???"
            if let symbol = frame["symbol"] as? String {
                let location = (frame["symbolLocation"] as? Int).map { " + \($0)" } ?? ""
                return clip("\(image)  \(symbol)\(location)") ?? image
            }
            let offset = (frame["imageOffset"] as? Int).map { String(format: "0x%lx", $0) } ?? "?"
            return clip("\(image)  \(offset)") ?? image
        }
    }

    /// Denetim karakterleri atılır, uzunluk sınırlanır; boşsa `nil`.
    static func clip(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > fieldLimit ? String(cleaned.prefix(fieldLimit)) + "…" : cleaned
    }

    /// "2026-10-18 01:51:54.00 +0300", kesirli kısım 0–6 basamak.
    static func parseDate(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let time = parts[1].split(separator: ".", maxSplits: 1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        guard var date = formatter.date(from: "\(parts[0]) \(time[0]) \(parts[2])") else { return nil }
        if time.count == 2, let fraction = Double("0." + time[1]) { date += fraction }
        return date
    }
}

/// macOS çökme raporları dizininde bir oturumun raporunu arar.
public struct CrashReportLocator: Sendable {
    public enum Result: Equatable, Sendable {
        case found(CrashSummary)
        case notFound
        /// Dizin okunamadı (izin, sandbox): "rapor yok" ile karıştırılmaz.
        case inaccessible
    }

    public var directory: URL
    /// Dosya adı öneki: "dev2kit-2026-10-21-222806.ips".
    public var processName: String
    /// `nil`: paket kimliği denetlenmez (paketsiz süreç).
    public var bundleID: String?

    public init(directory: URL = Self.defaultDirectory, processName: String, bundleID: String?) {
        self.directory = directory
        self.processName = processName
        self.bundleID = bundleID
    }

    /// `~/Library/Logs/DiagnosticReports`: kullanıcının kendi raporları.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
    }

    /// Dizin okunabiliyor mu (yoksa okunabilir sayılır: henüz rapor yok).
    public func isAccessible() -> Bool {
        if case .inaccessible = list() { return false }
        return true
    }

    public func find(for session: SessionRecord) -> Result {
        switch list() {
        case .inaccessible: return .inaccessible
        case .names(let names):
            let prefix = processName + "-"
            // Oturum başlamadan önce yazılmış dosyalara bakılmaz.
            let earliest = session.launchedAt.addingTimeInterval(-CrashReportParser.launchTolerance)
            for name in names.sorted(by: >) where name.hasPrefix(prefix) && name.hasSuffix(".ips") {
                let url = directory.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      (values.fileSize ?? .max) <= CrashReportParser.maximumFileSize,
                      (values.contentModificationDate ?? .distantFuture) >= earliest,
                      let data = try? Data(contentsOf: url),
                      let summary = CrashReportParser.summary(of: data, fileName: name, matching: session, bundleID: bundleID)
                else { continue }
                return .found(summary)
            }
            return .notFound
        }
    }

    private enum Listing { case names([String]), inaccessible }

    private func list() -> Listing {
        do {
            return .names(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .names([])
        } catch {
            return .inaccessible
        }
    }
}
