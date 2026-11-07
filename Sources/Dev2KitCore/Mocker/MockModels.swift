import Foundation

/// Mocker (2026-11-07): kullanıcının tanımladığı endpoint'lere yerel mock
/// response dönen hafif HTTP sunucusu. Bu dosya tanımları tutar; eşleşme
/// `MockRouter`, çakışma uyarıları `MockValidator`, sunucu `MockServer`.
///
/// Bir endpoint: metot (varsayılan Any) + yol (`/orders/{id}`, `*`) +
/// varsayılan response + isteğe bağlı senaryolar. Gelen istek bir senaryonun
/// TÜM koşullarını sağlarsa o senaryonun response'u, yoksa varsayılan döner.
public struct MockEndpoint: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var method: MockMethod
    public var path: String
    public var response: MockResponse
    public var scenarios: [MockScenario]
    /// Bu endpoint'e gelecek request gövdesinin örneği (kullanıcı isteği,
    /// 2026-11-07). Eşleşmeyi ETKİLEMEZ: ne gönderileceğini gösterir, cURL
    /// olarak kopyalanıp denenir.
    public var requestBody: String

    public init(
        id: UUID = UUID(),
        method: MockMethod = .any,
        path: String = "/",
        response: MockResponse = MockResponse(),
        scenarios: [MockScenario] = [],
        requestBody: String = ""
    ) {
        self.id = id
        self.method = method
        self.path = path
        self.response = response
        self.scenarios = scenarios
        self.requestBody = requestBody
    }

    /// Eksik alanlar varsayılanla dolar: ileride eklenen alan eski dosyayı bozmaz.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        method = (try? container.decodeIfPresent(MockMethod.self, forKey: .method)) ?? .any
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? "/"
        response = try container.decodeIfPresent(MockResponse.self, forKey: .response) ?? MockResponse()
        scenarios = try container.decodeIfPresent([MockScenario].self, forKey: .scenarios) ?? []
        requestBody = try container.decodeIfPresent(String.self, forKey: .requestBody) ?? ""
    }
}

/// Örnek request'i denemek için cURL komutu.
///
/// `CurlExporter` ile aynı güvenlik kuralları: tek tırnaklı alıntı, gövde
/// `--data-raw` (gövdedeki `@dosya` curl'de dosya OKUMAZ). `{{…}}` çözülmez:
/// Mocker değişken bilmiyor, metin olduğu gibi gider.
public enum MockRequestExample {
    public static func curl(method: MockMethod, baseURL: String, path: String, body: String) -> String {
        let hasBody = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let verb: String
        switch method {
        case .any: verb = hasBody ? "POST" : "GET"
        default: verb = method.rawValue
        }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let url = base + (path.hasPrefix("/") ? path : "/" + path)
        var parts = ["curl"]
        // `{id}`, `*`, `[`: curl bunları desen sanmasın.
        if url.contains(where: { "{}[]*".contains($0) }) { parts.append("--globoff") }
        parts.append("-X \(verb) \(quote(url))")
        if hasBody {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                parts.append("-H \(quote("Content-Type: application/json"))")
            }
            parts.append("--data-raw \(quote(body))")
        }
        return parts.joined(separator: " \\\n  ")
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum MockMethod: String, Codable, CaseIterable, Sendable {
    case any = "ANY"
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    public var title: String { self == .any ? "Any" : rawValue }

    public func accepts(_ method: String) -> Bool {
        self == .any || rawValue == method.uppercased()
    }

    /// İki tanım aynı metotla gelen isteği yakalayabilir mi.
    public func overlaps(_ other: MockMethod) -> Bool {
        self == .any || other == .any || self == other
    }
}

public struct MockResponse: Codable, Equatable, Sendable {
    public var status: Int
    public var headers: [KeyValueEntry]
    public var body: String
    /// Response'tan önce bekleme (timeout ve yavaş servis denemesi).
    public var delayMilliseconds: Int

    public init(
        status: Int = 200,
        headers: [KeyValueEntry] = [KeyValueEntry(key: "Content-Type", value: "application/json")],
        body: String = "{}",
        delayMilliseconds: Int = 0
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.delayMilliseconds = delayMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(Int.self, forKey: .status) ?? 200
        headers = try container.decodeIfPresent([KeyValueEntry].self, forKey: .headers) ?? []
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        delayMilliseconds = try container.decodeIfPresent(Int.self, forKey: .delayMilliseconds) ?? 0
    }

    /// Sunucunun kullandığı hal: durum ve gecikme sınırlar içinde.
    public var clamped: MockResponse {
        var copy = self
        copy.status = MockerLimits.statusRange.contains(status) ? status : 200
        copy.delayMilliseconds = min(max(delayMilliseconds, 0), MockerLimits.maxDelayMilliseconds)
        return copy
    }
}

public struct MockScenario: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var conditions: [MockCondition]
    public var response: MockResponse
    /// Gelen gövdenin karşılaştırılacağı örnek (boş: gövdeye bakılmaz). Koşullarla
    /// birlikte: gövde ve tüm koşullar tutmalı (kullanıcı isteği, 2026-11-07).
    public var requestBody: String
    public var bodyMatch: MockBodyMatch

    public init(
        id: UUID = UUID(),
        name: String = "",
        conditions: [MockCondition] = [],
        response: MockResponse = MockResponse(),
        requestBody: String = "",
        bodyMatch: MockBodyMatch = .contains
    ) {
        self.id = id
        self.name = name
        self.conditions = conditions
        self.response = response
        self.requestBody = requestBody
        self.bodyMatch = bodyMatch
    }

    public var hasRequestBody: Bool {
        !requestBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Seçilebilir mi: en az bir koşul ya da request body. İkisi de yoksa her
    /// isteği yakalardı; varsayılan response'un işi, bu yüzden hiç seçilmez.
    public var isActive: Bool { !conditions.isEmpty || hasRequestBody }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        conditions = try container.decodeIfPresent([MockCondition].self, forKey: .conditions) ?? []
        response = try container.decodeIfPresent(MockResponse.self, forKey: .response) ?? MockResponse()
        requestBody = try container.decodeIfPresent(String.self, forKey: .requestBody) ?? ""
        bodyMatch = (try? container.decodeIfPresent(MockBodyMatch.self, forKey: .bodyMatch)) ?? .contains
    }
}

/// Senaryonun bir koşulu: kaynak (header, query, JSON alanı…), ad, karşılaştırma, değer.
public struct MockCondition: Codable, Identifiable, Equatable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        case header
        case query
        /// Gövdedeki JSON alanı; `name` JSONPath (`$.amount`).
        case jsonBody
        /// Gövdenin ham metni; `name` kullanılmaz.
        case bodyText
        /// Yoldaki `{ad}` parçası.
        case pathParameter
    }

    public enum Comparison: String, Codable, CaseIterable, Sendable {
        case equals
        case notEquals
        case contains
        case exists
    }

    public var id: UUID
    public var source: Source
    public var name: String
    public var comparison: Comparison
    public var value: String

    public init(id: UUID = UUID(), source: Source = .header, name: String = "", comparison: Comparison = .equals, value: String = "") {
        self.id = id
        self.source = source
        self.name = name
        self.comparison = comparison
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = (try? container.decodeIfPresent(Source.self, forKey: .source)) ?? .header
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        comparison = (try? container.decodeIfPresent(Comparison.self, forKey: .comparison)) ?? .equals
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    /// Kaynak bir ad istiyor mu (gövde metni istemez).
    public var usesName: Bool { source != .bodyText }
    /// Karşılaştırma bir değer istiyor mu ("var" istemez).
    public var usesValue: Bool { comparison != .exists }
}

/// Diskteki dosyanın içeriği.
public struct MockerDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var endpoints: [MockEndpoint]

    public init(endpoints: [MockEndpoint] = []) {
        self.version = Self.currentVersion
        self.endpoints = endpoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        endpoints = try container.decodeIfPresent([MockEndpoint].self, forKey: .endpoints) ?? []
    }
}

/// Mocker'ın sayısal sınırları (tek yerde, UI-KURALLARI §5b).
public enum MockerLimits {
    /// Sırayla denenen portlar (kullanıcı kararı, 2026-11-07).
    public static let ports: [UInt16] = [8098, 8099, 8100]
    public static let maxEndpoints = 500
    public static let maxScenarios = 50
    public static let maxConditions = 20
    /// Tanımdaki response gövdesi (editör sınırı).
    public static let maxResponseBodyBytes = 2_000_000
    /// Gelen istek: başlık bölümü ve gövde. Aşan istek 431 / 413 alır.
    public static let maxRequestHeadBytes = 64 * 1024
    public static let maxRequestBodyBytes = 10_000_000
    public static let maxDelayMilliseconds = 120_000
    /// 1xx son yanıt olamaz (istemci ara yanıt sanar); 200–599.
    public static let statusRange = 200...599
    /// Aynı anda açık bağlantı; fazlası hemen kapatılır.
    public static let maxConnections = 64
    /// Boşta bekleyen (keep-alive) bağlantı bu süre sonra kapanır.
    public static let idleConnectionSeconds: Double = 15
    /// Bu süre hiç istek gelmezse Mocker kendini durdurur (kullanıcı isteği,
    /// 2026-11-07: kaynak korumak için). Başlat ve Uygula da süreyi yeniler.
    public static let idleStopSeconds: Double = 10 * 60
    /// Bellekteki istek kaydı (diske yazılmaz).
    public static let logCapacity = 200
    public static let logBodyPreviewBytes = 4_096
}
