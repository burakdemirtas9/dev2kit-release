import Darwin
import Foundation

/// Donma bekçisinin kuralları (2026-10-31).
///
/// Neden: 181'de bir kullanıcının uygulaması dakikalarca yanıt vermedi, bellek
/// 4–5 GB'a çıktı; zorla kapatıldığı için hiçbir iz kalmadı. Bekçi ayrı bir
/// iş parçacığından ana iş parçacığını yoklar; donma olursa içeriksiz bir
/// kayıt bırakır, kaçak durumda (donma + bellek) uygulamayı çökme raporu
/// bırakarak kapatır.
///
/// Burada yalnızca karar var (saf, testli). Zaman, uyku saymayan bir saatin
/// saniyesidir (`SuspendingClock`): Mac uyurken geçen süre donma sayılmaz.
public struct HangWatchdogPolicy: Sendable {
    public struct Thresholds: Equatable, Sendable {
        /// Ana iş parçacığı bu kadar saniye yanıt vermezse donma.
        public var hangSeconds: Double = 10
        /// Donmayla birlikte bu belleğe ulaşılırsa kapatılır; tek başına
        /// aşılırsa yalnızca kaydedilir.
        public var memoryLimitMB = 2_048
        /// Bellek uyarısı bunun altına inince yeniden kurulur (tekrar tekrar
        /// yazılmasın).
        public var memoryRearmMB = 1_536
        /// Açılıştan, uyanıştan ve kilit açılışından sonra hiçbir şey
        /// söylenmeyen süre: sistem toparlanırken gecikme olağan.
        public var graceSeconds: Double = 30

        public init() {}
    }

    public enum Action: Equatable, Sendable {
        case recordHang(stallSeconds: Int)
        case recordRecovered(stallSeconds: Int)
        case recordHighMemory
        /// Kayıt yazılır, uygulama çökme raporu bırakarak kapatılır.
        case terminate(stallSeconds: Int)
    }

    public let thresholds: Thresholds
    private var graceUntil: Double
    /// Susturmanın bittiği an: donma süresi bundan önce başlamış sayılmaz.
    private var baseline: Double
    private var wasSuppressed = false
    private var inHang = false
    private var longestStall: Double = 0
    private var memoryReported = false
    /// Bellek sınırının üstüne çıkılan an. Uyarı ancak donma OLMADAN
    /// `hangSeconds` boyunca üstte kalınca yazılır: donmanın ilk saniyesinde
    /// "yanıt veriyor ama bellek yüksek" demek yanıltıcı olurdu.
    private var memoryOverSince: Double?
    private var terminated = false

    public init(thresholds: Thresholds = Thresholds(), startedAt now: Double) {
        self.thresholds = thresholds
        graceUntil = now + thresholds.graceSeconds
        baseline = now
    }

    /// Bekçinin her yoklamasında. `lastHeartbeat`: ana iş parçacığının son
    /// yanıt verdiği an. `suppressed`: uyku, ekran uykusu ya da kilidi, oturum
    /// devri ya da pencere görünmüyor; o sırada hiçbir şey yapılmaz.
    public mutating func evaluate(now: Double, lastHeartbeat: Double, memoryMB: Int, suppressed: Bool) -> [Action] {
        guard !terminated else { return [] }
        if suppressed {
            wasSuppressed = true
            inHang = false
            longestStall = 0
            return []
        }
        if wasSuppressed {
            wasSuppressed = false
            baseline = now
            graceUntil = max(graceUntil, now + thresholds.graceSeconds)
        }

        var actions: [Action] = []
        let stall = max(0, now - max(lastHeartbeat, baseline))
        let overLimit = memoryMB >= thresholds.memoryLimitMB

        if inHang {
            if stall < thresholds.hangSeconds {
                actions.append(.recordRecovered(stallSeconds: Int(longestStall.rounded())))
                inHang = false
                longestStall = 0
            } else {
                longestStall = max(longestStall, stall)
                if overLimit { actions.append(terminate(stall)) }
            }
        } else if now >= graceUntil, stall >= thresholds.hangSeconds {
            inHang = true
            longestStall = stall
            actions.append(.recordHang(stallSeconds: Int(stall.rounded())))
            if overLimit { actions.append(terminate(stall)) }
        }

        if !terminated {
            if overLimit {
                let since = memoryOverSince ?? now
                memoryOverSince = since
                if !memoryReported, !inHang, stall < thresholds.hangSeconds, now - since >= thresholds.hangSeconds {
                    memoryReported = true
                    actions.append(.recordHighMemory)
                }
            } else {
                memoryOverSince = nil
                if memoryReported, memoryMB < thresholds.memoryRearmMB { memoryReported = false }
            }
        }
        return actions
    }

    private mutating func terminate(_ stall: Double) -> Action {
        terminated = true
        return .terminate(stallSeconds: Int(stall.rounded()))
    }
}

/// Kaba boyut aralığı: tanılamada kesin uzunluk yazılmaz (bir token'ın ya da
/// değerin boyu ima edilmesin), teşhis için büyüklük mertebesi yeter.
/// Sayılar (header adedi) ve boyutlar (karakter, bayt) için aynı aralıklar.
public enum DiagnosticSize: String, Codable, Sendable, CaseIterable {
    case zero
    case upTo10
    case upTo100
    case upTo1K
    case upTo10K
    case upTo100K
    case upTo1M
    case upTo10M
    case over10M

    public init(_ value: Int) {
        switch value {
        case ..<1: self = .zero
        case ...10: self = .upTo10
        case ...100: self = .upTo100
        case ...1_000: self = .upTo1K
        case ...10_000: self = .upTo10K
        case ...100_000: self = .upTo100K
        case ...1_000_000: self = .upTo1M
        case ...10_000_000: self = .upTo10M
        default: self = .over10M
        }
    }
}

/// Donma anında kullanıcının nerede olduğu ve verinin büyüklüğü.
///
/// Gizlilik tip düzeyinde (`DiagnosticEvent` ile aynı ilke): yalnızca kapalı
/// tür listeleri, kaba aralıklar ve tam sayılar. İstek adı, adres, header
/// adı/değeri, gövde ya da yanıt içeriği buraya yazılacak bir yer bulamaz.
public struct DiagnosticContext: Codable, Equatable, Sendable {
    public enum Screen: String, Codable, Sendable {
        case apiClientNoRequest
        case apiClientHeaders
        case apiClientBody
        case apiClientAuth
        case apiClientParams
        case apiClientToken
        case apiClientExample
        case workbench
        case mocker
    }

    public enum ContentKind: String, Codable, Sendable {
        case json, markup, javascript, css, sql, markdown, plain
    }

    public var screen: Screen?
    public var headerCount: DiagnosticSize?
    /// En uzun header değeri (karakter).
    public var longestHeaderValue: DiagnosticSize?
    /// Header değerlerindeki `{{` sayısı (yaklaşık; çok büyük değerlerde ilk
    /// `variableScanLimit` karakter sayılır).
    public var headerVariables: DiagnosticSize?
    /// Gövde (karakter; form gövdesinde alanların toplamı).
    public var bodySize: DiagnosticSize?
    /// Yanıt gövdesi (bayt).
    public var responseSize: DiagnosticSize?
    public var responseKind: ContentKind?
    /// Fiziksel bellek ayak izi, 10 MB'a yuvarlanmış.
    public var memoryMB: Int?
    /// Ana iş parçacığının yanıt vermediği süre (saniye).
    public var stallSeconds: Int?

    public init(
        screen: Screen? = nil,
        headerCount: DiagnosticSize? = nil,
        longestHeaderValue: DiagnosticSize? = nil,
        headerVariables: DiagnosticSize? = nil,
        bodySize: DiagnosticSize? = nil,
        responseSize: DiagnosticSize? = nil,
        responseKind: ContentKind? = nil,
        memoryMB: Int? = nil,
        stallSeconds: Int? = nil
    ) {
        self.screen = screen
        self.headerCount = headerCount
        self.longestHeaderValue = longestHeaderValue
        self.headerVariables = headerVariables
        self.bodySize = bodySize
        self.responseSize = responseSize
        self.responseKind = responseKind
        self.memoryMB = memoryMB
        self.stallSeconds = stallSeconds
    }

    /// Her saniye ana iş parçacığında hesaplandığı için tarama sınırlı.
    public static let variableScanLimit = 256 * 1024

    /// Header'lardan: adet, en uzun değer, `{{` sayısı. Uzunluk UTF-8 sayımı
    /// (yerel dizgide sabit zaman); tarama toplamda `variableScanLimit` bayt.
    public static func headerFigures(_ headers: [KeyValueEntry]) -> (count: DiagnosticSize, longest: DiagnosticSize, variables: DiagnosticSize) {
        var longest = 0
        var variables = 0
        var budget = variableScanLimit
        for entry in headers {
            let utf8 = entry.value.utf8
            longest = max(longest, utf8.count)
            guard budget > 0 else { continue }
            var previous: UInt8 = 0
            for byte in utf8.prefix(budget) {
                if byte == 0x7B, previous == 0x7B { variables += 1; previous = 0 } else { previous = byte }
            }
            budget -= min(budget, utf8.count)
        }
        return (DiagnosticSize(headers.count), DiagnosticSize(longest), DiagnosticSize(variables))
    }

    /// Okunur tek satır (panodaki rapor metni): yalnızca alan adları ve
    /// kapalı değerler.
    public var summary: String {
        var parts: [String] = []
        if let screen { parts.append("screen=\(screen.rawValue)") }
        if let headerCount { parts.append("headers=\(headerCount.rawValue)") }
        if let longestHeaderValue { parts.append("longestHeader=\(longestHeaderValue.rawValue)") }
        if let headerVariables { parts.append("headerVariables=\(headerVariables.rawValue)") }
        if let bodySize { parts.append("body=\(bodySize.rawValue)") }
        if let responseSize { parts.append("response=\(responseSize.rawValue)") }
        if let responseKind { parts.append("responseKind=\(responseKind.rawValue)") }
        if let memoryMB { parts.append("memory=\(memoryMB)MB") }
        if let stallSeconds { parts.append("stall=\(stallSeconds)s") }
        return parts.joined(separator: " ")
    }
}

/// Sürecin fiziksel bellek ayak izi (Etkinlik Monitörü'ndeki "Bellek").
public enum ProcessMemory {
    public static func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    /// Tanılamaya yazılan değer: 10 MB'a yuvarlanmış.
    public static func rounded(_ megabytes: Int) -> Int {
        megabytes / 10 * 10
    }
}

/// "Bekçi kapattı" işareti: kapatmadan hemen önce yazılır, sonraki açılışta
/// bir kez okunup silinir (kullanıcıya neden kapandığı söylenir).
public struct WatchdogTermination: Codable, Equatable, Sendable {
    public var time: Date
    public var stallSeconds: Int
    public var memoryMB: Int

    public init(time: Date, stallSeconds: Int, memoryMB: Int) {
        self.time = time
        self.stallSeconds = stallSeconds
        self.memoryMB = memoryMB
    }

    static let fileName = "watchdog-terminated.json"

    /// Bekçi iş parçacığından, kapatmadan önce (eşzamanlı, atomik).
    public static func write(_ record: WatchdogTermination, in directory: URL) {
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? AtomicFile.write(data, to: directory.appendingPathComponent(fileName))
    }

    /// Açılışta (arka planda): varsa okur ve siler.
    public static func consume(in directory: URL) -> WatchdogTermination? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try? decoder.decode(WatchdogTermination.self, from: data)
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
