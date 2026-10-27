import Foundation

/// Yerel tanılama günlüğündeki bir olay.
///
/// Gizlilik tip düzeyinde: olay yalnızca kapalı bir tür listesi, isteğe bağlı
/// bir durum kodu ve hata ALANI + KODU taşır. Serbest metin alanı yok; token,
/// parola, cookie, anahtar, environment değeri ya da istek/yanıt içeriği
/// buraya yazılacak bir yer bulamaz. Hata mesajı (`localizedDescription`)
/// bilerek alınmaz: dosya yolu veya sunucu yanıtı taşıyabilir.
public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case sessionStarted
        case sessionEnded
        case previousSessionUnclean
        case crashReportFound
        case storageRecovered
        case storageOpenFailed
        case storageSaveFailed
        case secretStoreUnavailable
        /// Geçmişin anahtarı alınamadı ya da Keychain'e taşınamadı.
        case historyKeyUnavailable
    }

    /// Kayıt açılışındaki durum ayrıntısı (`StoreNotice` türleri gibi).
    public enum Detail: String, Codable, Sendable {
        case migrated
        case recoveredInterruptedSave
        case restoredFromBackup
        case partiallyLoaded
        case legacyUnreadable
    }

    public var time: Date
    public var kind: Kind
    public var detail: Detail?
    public var errorDomain: String?
    public var errorCode: Int?

    public init(kind: Kind, time: Date = Date(), detail: Detail? = nil, error: Error? = nil) {
        self.time = time
        self.kind = kind
        self.detail = detail
        if let error {
            let nsError = error as NSError
            self.errorDomain = Self.safeDomain(nsError.domain)
            self.errorCode = nsError.code
        }
    }

    /// Alan adı tür adıdır ("NSCocoaErrorDomain", "Dev2KitCore.StoreError");
    /// beklenmedik karakter içeriyorsa yazılmaz.
    static func safeDomain(_ domain: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._")
        guard !domain.isEmpty, domain.count <= 80, domain.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return domain
    }
}

/// Yerel, boyutu ve süresi sınırlı tanılama günlüğü (JSON Lines).
///
/// - Yalnızca yerelde; hiçbir yere gönderilmez.
/// - `diagnostics/events.log` + bir önceki `events.1.log`: her biri en çok
///   `maximumFileSize`; dolunca döndürülür. `retention`'dan eski olaylar
///   açılışta atılır.
/// - Yazım tek seri kuyrukta, arka planda: arayüzü bekletmez. Yazılamazsa
///   sessizce vazgeçer (tanılama, uygulamayı bozacak yeni bir hata kaynağı
///   olmamalı).
/// - `activate` çağrılana kadar olaylar bellekte bekler (sınırlı): testlerde
///   ve paketsiz çalıştırmada diske hiç yazılmaz.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog()

    public static let maximumFileSize = 256 * 1024
    public static let retention: TimeInterval = 14 * 24 * 60 * 60
    /// Etkinleştirmeden önce bellekte tutulan en çok olay.
    static let pendingLimit = 100

    private let queue = DispatchQueue(label: "dev2kit.diagnostics", qos: .utility)
    private var directory: URL?
    private var pending: [DiagnosticEvent] = []
    let maximumFileSize: Int
    let retention: TimeInterval

    public init(maximumFileSize: Int = DiagnosticLog.maximumFileSize, retention: TimeInterval = DiagnosticLog.retention) {
        self.maximumFileSize = maximumFileSize
        self.retention = retention
    }

    var currentURL: URL? { directory?.appendingPathComponent("events.log") }
    var previousURL: URL? { directory?.appendingPathComponent("events.1.log") }

    /// Diske yazmaya başlar; bekleyen olaylar yazılır, eskiler atılır.
    public func activate(directory: URL, now: Date = Date()) {
        queue.async {
            self.directory = directory
            self.prune(now: now)
            let waiting = self.pending
            self.pending = []
            waiting.forEach(self.append)
        }
    }

    public func record(_ event: DiagnosticEvent) {
        queue.async {
            guard self.directory != nil else {
                if self.pending.count < Self.pendingLimit { self.pending.append(event) }
                return
            }
            self.append(event)
        }
    }

    /// Bekleyen yazımların bitmesini bekler (kapanışta ve testlerde).
    public func flush() {
        queue.sync {}
    }

    /// En yeni `limit` olay, eskiden yeniye.
    public func recentEvents(limit: Int = 20) -> [DiagnosticEvent] {
        queue.sync {
            let lines = [previousURL, currentURL].compactMap { $0 }.flatMap(Self.lines(in:))
            return Array(lines.compactMap(Self.decode).suffix(limit))
        }
    }

    // MARK: - Kuyruk içinde

    private func append(_ event: DiagnosticEvent) {
        guard let currentURL, let previousURL,
              var line = try? Self.encoder.encode(event) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: currentURL.path)[.size] as? Int) ?? 0
        if size + line.count > maximumFileSize {
            try? manager.removeItem(at: previousURL)
            try? manager.moveItem(at: currentURL, to: previousURL)
        }
        if !manager.fileExists(atPath: currentURL.path) {
            try? manager.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            guard manager.createFile(atPath: currentURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        }
        guard let handle = try? FileHandle(forWritingTo: currentURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Süresi dolan olayları atar (dosyalar küçük: en çok 2 × 256 KB).
    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        for url in [previousURL, currentURL].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            let lines = Self.lines(in: url)
            let kept = lines.filter { Self.decode($0).map { $0.time >= cutoff } ?? false }
            guard kept.count != lines.count else { continue }
            if kept.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try? AtomicFile.write(Data(kept.joined(separator: "\n").utf8 + [0x0A]), to: url)
            }
        }
    }

    private static func lines(in url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private static func decode(_ line: String) -> DiagnosticEvent? {
        try? decoder.decode(DiagnosticEvent.self, from: Data(line.utf8))
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

public extension StoreNotice {
    /// Günlükte yalnızca türü (yollar ve dosya adları yazılmaz).
    var diagnosticDetail: DiagnosticEvent.Detail {
        switch self {
        case .migrated: .migrated
        case .recoveredInterruptedSave: .recoveredInterruptedSave
        case .restoredFromBackup: .restoredFromBackup
        case .partiallyLoaded: .partiallyLoaded
        case .legacyUnreadable: .legacyUnreadable
        }
    }
}
