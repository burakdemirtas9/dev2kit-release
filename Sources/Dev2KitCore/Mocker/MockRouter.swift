import Foundation

/// Endpoint yolu: `/orders/{id}/items/*`. `{ad}` ve `*` tek bir yol parçasını
/// karşılar; `{ad}`'ın değeri koşullarda kullanılabilir. Query ve `#` yoksayılır,
/// boş parçalar (`//`, sondaki `/`) atılır, yüzde kodlaması çözülerek karşılaştırılır.
public struct MockPathPattern: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case literal(String)
        case parameter(String)
        case wildcard

        var isLiteral: Bool {
            if case .literal = self { return true }
            return false
        }
    }

    public let segments: [Segment]

    public init(_ path: String) {
        segments = Self.split(path).map { raw in
            if raw == "*" { return .wildcard }
            if raw.count >= 2, raw.hasPrefix("{"), raw.hasSuffix("}") {
                return .parameter(String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
            }
            return .literal(raw.removingPercentEncoding ?? raw)
        }
    }

    static func split(_ path: String) -> [String] {
        var trimmed = Substring(path)
        if let end = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) { trimmed = trimmed[..<end] }
        return trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Eşleşirse yol değişkenleri (`{id}` → "42"), eşleşmezse `nil`.
    public func match(_ path: String) -> [String: String]? {
        let parts = Self.split(path)
        guard parts.count == segments.count else { return nil }
        var parameters: [String: String] = [:]
        for (segment, raw) in zip(segments, parts) {
            let value = raw.removingPercentEncoding ?? raw
            switch segment {
            case .literal(let text):
                guard text == value else { return nil }
            case .parameter(let name):
                parameters[name] = value
            case .wildcard:
                break
            }
        }
        return parameters
    }

    public var literalCount: Int { segments.filter(\.isLiteral).count }

    public var parameterNames: [String] {
        segments.compactMap {
            if case .parameter(let name) = $0 { return name }
            return nil
        }
    }

    /// Aynı somut yolu ikisi de karşılayabilir mi.
    public func overlaps(_ other: MockPathPattern) -> Bool {
        guard segments.count == other.segments.count else { return false }
        return zip(segments, other.segments).allSatisfy { left, right in
            if case .literal(let a) = left, case .literal(let b) = right { return a == b }
            return true
        }
    }

    /// Aynı yolları karşılıyor (değişken adı farkı önemsiz): biri ötekini tamamen örter.
    public func hasSameShape(as other: MockPathPattern) -> Bool {
        guard segments.count == other.segments.count else { return false }
        return zip(segments, other.segments).allSatisfy { left, right in
            switch (left, right) {
            case let (.literal(a), .literal(b)): return a == b
            case (.literal, _), (_, .literal): return false
            default: return true
            }
        }
    }
}

/// Sunucuya gelen istek (ayrıştırılmış).
public struct MockIncomingRequest: Sendable {
    public var method: String
    /// İstek satırındaki hedef: `/a/b?x=1` (ya da proxy biçimi `http://h/a`).
    public var target: String
    public var headers: [MockHeader]
    public var body: Data

    public init(method: String, target: String, headers: [MockHeader] = [], body: Data = Data()) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    /// Yol (query'siz). Mutlak biçimde (`http://host/yol`) yalnızca yol alınır.
    public var path: String {
        var value = Substring(target)
        if value.hasPrefix("http://") || value.hasPrefix("https://"),
           let schemeEnd = value.range(of: "://") {
            let afterHost = value[schemeEnd.upperBound...]
            value = afterHost.firstIndex(of: "/").map { afterHost[$0...] } ?? "/"
        }
        if let end = value.firstIndex(where: { $0 == "?" || $0 == "#" }) { value = value[..<end] }
        return value.isEmpty ? "/" : String(value)
    }

    /// Query parametreleri (yüzde kodu ve `+` çözülmüş); aynı ad birden çok olabilir.
    public var queryItems: [(name: String, value: String)] {
        guard let start = target.firstIndex(of: "?") else { return [] }
        var query = target[target.index(after: start)...]
        if let fragment = query.firstIndex(of: "#") { query = query[..<fragment] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ text: Substring) -> String {
                let spaced = text.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            return (decode(parts[0]), parts.count > 1 ? decode(parts[1]) : "")
        }
    }

    public func headerValues(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }
}

public struct MockHeader: Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// İsteğe verilen karar: hangi endpoint, hangi senaryo, hangi response.
public struct MockRoute: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case scenario(id: UUID, name: String)
        case defaultResponse
        case noEndpoint
    }

    public let endpointID: UUID?
    public let outcome: Outcome
    public let response: MockResponse
}

/// Gelen isteği tanımlarla eşleştirir.
///
/// Endpoint seçimi (çakışmada, kullanıcıya `MockValidator` söyler):
/// 1. Daha çok sabit yol parçası olan (`/orders/42` > `/orders/{id}`),
/// 2. eşitse metodu belirli olan (POST > Any),
/// 3. o da eşitse listede üstte olan.
/// Senaryo: request body'si (varsa) ve TÜM koşulları tutan ilk senaryo; koşulu
/// da gövdesi de olmayan senaryo seçilmez. Hiçbiri tutmazsa varsayılan.
public enum MockRouter {
    public static func route(_ request: MockIncomingRequest, endpoints: [MockEndpoint]) -> MockRoute {
        let path = request.path
        var best: (endpoint: MockEndpoint, parameters: [String: String], rank: Rank)?
        for endpoint in endpoints where accepts(endpoint.method, request.method) {
            let pattern = MockPathPattern(endpoint.path)
            guard let parameters = pattern.match(path) else { continue }
            let rank = Rank(pattern: pattern, method: endpoint.method)
            // Eşitlikte üstteki kalır.
            if best == nil || rank > best!.rank {
                best = (endpoint, parameters, rank)
            }
        }
        guard let best else { return notFound(request) }
        let context = MockMatchContext(request: request, pathParameters: best.parameters)
        for scenario in best.endpoint.scenarios where scenario.isActive {
            if context.matchesBody(of: scenario), scenario.conditions.allSatisfy(context.satisfies) {
                return MockRoute(endpointID: best.endpoint.id,
                                 outcome: .scenario(id: scenario.id, name: scenario.name),
                                 response: scenario.response.clamped)
            }
        }
        return MockRoute(endpointID: best.endpoint.id, outcome: .defaultResponse, response: best.endpoint.response.clamped)
    }

    /// GET tanımı HEAD isteğini de karşılar (gövdesiz yanıt; sunucular böyle yapar).
    static func accepts(_ method: MockMethod, _ requestMethod: String) -> Bool {
        method.accepts(requestMethod) || (method == .get && requestMethod.uppercased() == "HEAD")
    }

    struct Rank: Comparable {
        let literals: Int
        let specificMethod: Bool

        init(pattern: MockPathPattern, method: MockMethod) {
            literals = pattern.literalCount
            specificMethod = method != .any
        }

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            if lhs.literals != rhs.literals { return lhs.literals < rhs.literals }
            return !lhs.specificMethod && rhs.specificMethod
        }
    }

    static func notFound(_ request: MockIncomingRequest) -> MockRoute {
        let message = "No mock endpoint for \(request.method) \(request.path)"
        let body = "{\n  \"error\": \(JSONValue.quoted(message)),\n  \"source\": \"dev2kit Mocker\"\n}"
        return MockRoute(endpointID: nil, outcome: .noEndpoint,
                         response: MockResponse(status: 404, body: body))
    }
}

/// Bir isteğin koşul değerlendirmesi. Gövde ve JSON bir kez okunur.
final class MockMatchContext {
    private let request: MockIncomingRequest
    private let pathParameters: [String: String]
    private lazy var bodyText = String(decoding: request.body, as: UTF8.self)
    private lazy var query = request.queryItems
    private var parsedJSON: JSONValue??

    init(request: MockIncomingRequest, pathParameters: [String: String]) {
        self.request = request
        self.pathParameters = pathParameters
    }

    private var json: JSONValue? {
        if let parsedJSON { return parsedJSON }
        let value = try? JSONDocument.parse(bodyText)
        parsedJSON = .some(value)
        return value
    }

    func matchesBody(of scenario: MockScenario) -> Bool {
        guard scenario.hasRequestBody else { return true }
        return MockBodyMatcher.matches(MockBodyMatcher.example(scenario.requestBody), mode: scenario.bodyMatch,
                                       actualText: bodyText, actualJSON: { self.json })
    }

    func satisfies(_ condition: MockCondition) -> Bool {
        let expected = condition.value.trimmingCharacters(in: .whitespaces)
        switch condition.source {
        case .jsonBody:
            guard let root = json, let values = try? JSONPath.evaluate(condition.name, on: root) else {
                return condition.comparison == .notEquals
            }
            return Self.compare(values.map(JSONMatch.init), condition.comparison, expected)
        case .bodyText:
            let text = bodyText
            switch condition.comparison {
            case .exists: return !request.body.isEmpty
            case .equals: return text.trimmingCharacters(in: .whitespacesAndNewlines) == condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .notEquals: return text.trimmingCharacters(in: .whitespacesAndNewlines) != condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .contains: return !condition.value.isEmpty && text.contains(condition.value)
            }
        case .header:
            let values = request.headerValues(condition.name.trimmingCharacters(in: .whitespaces))
            return Self.compare(values.map { JSONMatch(text: $0.trimmingCharacters(in: .whitespaces)) }, condition.comparison, expected)
        case .query:
            let name = condition.name.trimmingCharacters(in: .whitespaces)
            let values = query.filter { $0.name == name }.map { JSONMatch(text: $0.value) }
            return Self.compare(values, condition.comparison, expected)
        case .pathParameter:
            let name = condition.name.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            let values = pathParameters[name].map { [JSONMatch(text: $0)] } ?? []
            return Self.compare(values, condition.comparison, expected)
        }
    }

    /// "Eşit değil": hiçbir değer eşit değilse (alan hiç yoksa da) tutar.
    private static func compare(_ values: [JSONMatch], _ comparison: MockCondition.Comparison, _ expected: String) -> Bool {
        switch comparison {
        case .exists: return !values.isEmpty
        case .equals: return values.contains { $0.equals(expected) }
        case .notEquals: return !values.contains { $0.equals(expected) }
        case .contains: return !expected.isEmpty && values.contains { $0.text.contains(expected) }
        }
    }

    /// Karşılaştırılan değer: metin ve (JSON'dan geldiyse) sayı mı.
    struct JSONMatch {
        let text: String
        let isNumber: Bool

        init(text: String) {
            self.text = text
            isNumber = false
        }

        init(_ value: JSONValue) {
            switch value {
            case .string(let string): text = string; isNumber = false
            case .number(let number): text = number; isNumber = true
            case .bool(let bool): text = bool ? "true" : "false"; isNumber = false
            case .null: text = "null"; isNumber = false
            case .object, .array: text = value.compact(); isNumber = false
            }
        }

        /// JSON sayısında 100 = 100.0 = 1e2; diğerlerinde birebir.
        func equals(_ expected: String) -> Bool {
            if text == expected { return true }
            if isNumber, let left = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
               let right = Decimal(string: expected, locale: Locale(identifier: "en_US_POSIX")),
               expected.allSatisfy({ $0.isNumber || "+-.eE".contains($0) }) {
                return left == right
            }
            if text.hasPrefix("{") || text.hasPrefix("["),
               let parsed = try? JSONDocument.parse(expected) {
                return parsed.compact(sortKeys: true) == ((try? JSONDocument.parse(text))?.compact(sortKeys: true) ?? text)
            }
            return false
        }
    }
}
