import Foundation

/// Kibana'dan kopyalanan gelen-istek log kaydını dev2kit isteğine çevirir.
///
/// Beklenen şema (şirket içi log formatı; Kibana yalnızca gösterir):
/// `_index`, `_source.{http_method, request_path, request_body, headers, service_name}`.
/// `_source` yoksa aynı alanlar `fields` altındaki dizilerden okunur.
///
/// Host logda anlamlı değildir (cluster içi adres); yerine ortam ve servis
/// adından türetilen bir environment değişkeni kullanılır:
/// `{{test-finance-fx-bff-service}}/yol`. Gateway adresi ortama göre elle girilir.
///
/// Her ortamın logu aktarılır (test, dev, staging, prod…). Ortam yalnızca
/// değişken adı içindir; kayıt ortamına göre REDDEDİLMEZ. Eskiden yalnızca
/// test benzeri ortamlar alınıyordu; uygulama yerel ve özelliği kullananlar
/// prod loglarına zaten erişebiliyor (kullanıcı kararı, 2026-10-20). Ortam
/// anlaşılamazsa değişken yalnızca servis adıdır. Veri yalnızca yerelde
/// işlenir.
public enum KibanaImporter {
    public struct Entry: Identifiable, Sendable {
        public let id: String
        public let method: HTTPMethod
        /// Sorgu parametreleri ayrılmış yol.
        public let path: String
        public let query: [KeyValueEntry]
        public let body: String?
        public let headers: [ClassifiedHeader]
        public let serviceName: String
        /// Index adından: "test", "prod"…; tanınmazsa `nil` (kayıt yine alınır).
        public let environment: String?
        public let indexName: String
        public let loggedStatus: String?
        public let loggedAt: String?
        public let warnings: [String]

        public var variableName: String {
            environment.map { "\($0)-\(serviceName)" } ?? serviceName
        }
        public var urlTemplate: String { "{{\(variableName)}}\(path)" }

        /// Varsayılan seçim: yalnızca normal başlıklar. Hassas ve izleme
        /// başlıkları kullanıcı açıkça seçerse alınır.
        public var defaultHeaderSelection: Set<String> {
            Set(headers.filter { $0.category == .normal }.map(\.id))
        }
    }

    public struct ParseResult: Sendable {
        public let entries: [Entry]
        /// Alınmayan kayıtlar ve sebebi (eksik zorunlu alan). Ortam sebep değildir.
        public let rejected: [String]
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case invalidJSON
        case noDocuments

        public var errorDescription: String? {
            switch self {
            case .invalidJSON: return "Geçerli bir JSON değil."
            case .noDocuments: return "Kibana kaydı bulunamadı (_source ya da fields alanı yok)."
            }
        }
    }

    /// Index adının başında ortam olarak tanınan adlar. Yalnızca değişken
    /// adını kurmak için: `incoming-log-…` gibi ortamsız bir index'in ilk
    /// parçası ("incoming") ortam sanılmasın. Listede olmayan kayıt REDDEDİLMEZ.
    static let knownEnvironments: Set<String> = [
        "test", "dev", "development", "qa", "uat", "sit", "int", "stage", "staging", "stg", "prep", "preprod", "pre",
        "prod", "prd", "production", "live", "canary", "demo", "sandbox", "perf",
    ]

    public static func parse(_ data: Data) throws -> ParseResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw ImportError.invalidJSON }
        let documents = documents(in: json)
        guard !documents.isEmpty else { throw ImportError.noDocuments }

        var entries: [Entry] = []
        var rejected: [String] = []
        for (index, document) in documents.enumerated() {
            switch entry(from: document, position: index + 1) {
            case .success(let entry): entries.append(entry)
            case .failure(let reason): rejected.append(reason.message)
            }
        }
        return ParseResult(entries: entries, rejected: rejected)
    }

    // MARK: - Belge bulma

    /// Tek kayıt, kayıt dizisi ya da arama yanıtı (`hits.hits`).
    private static func documents(in json: Any) -> [[String: Any]] {
        if let array = json as? [[String: Any]] {
            return array.filter(isDocument)
        }
        guard let object = json as? [String: Any] else { return [] }
        if let hits = (object["hits"] as? [String: Any])?["hits"] as? [[String: Any]] {
            return hits.filter(isDocument)
        }
        return isDocument(object) ? [object] : []
    }

    private static func isDocument(_ object: [String: Any]) -> Bool {
        object["_source"] is [String: Any] || object["fields"] is [String: Any]
    }

    // MARK: - Kayıt çözümleme

    private struct Rejection: Error { let message: String }

    private static func entry(from document: [String: Any], position: Int) -> Result<Entry, Rejection> {
        let fields = Fields(document: document)
        let indexName = document["_index"] as? String ?? ""
        let label = "Kayıt \(position)"

        let environment = environment(fromIndex: indexName)
        guard let rawPath = fields.string("request_path"), !rawPath.isEmpty else {
            return .failure(Rejection(message: "\(label): request_path yok."))
        }
        guard let serviceName = fields.string("service_name")?.trimmingCharacters(in: .whitespaces),
              !serviceName.isEmpty else {
            return .failure(Rejection(message: "\(label): service_name yok; adres değişkeni türetilemiyor."))
        }

        var warnings: [String] = []
        let methodText = (fields.string("http_method") ?? "GET").uppercased()
        let method = HTTPMethod(rawValue: methodText) ?? {
            warnings.append("Desteklenmeyen metot \"\(methodText)\"; GET olarak alındı.")
            return .get
        }()

        let (path, query) = splitPath(rawPath)
        let headers = fields.headers()
            .map { HeaderClassifier.classify(name: $0.name, value: $0.value) }
            .sorted { ($0.category.rawValue, $0.id) < ($1.category.rawValue, $1.id) }
        let body = fields.string("request_body").flatMap { $0.isEmpty ? nil : $0 }

        return .success(Entry(
            id: document["_id"] as? String ?? "\(position)",
            method: method,
            path: path,
            query: query,
            body: body,
            headers: headers,
            serviceName: serviceName,
            environment: environment,
            indexName: indexName,
            loggedStatus: fields.string("status_code"),
            loggedAt: fields.string("start_time") ?? fields.string("timeStamp"),
            warnings: warnings
        ))
    }

    /// `test-incoming-log-2026.09.13-000909` → `test`, `prod-…` → `prod`.
    /// Uzak küme öneki (`kume:test-…`) ve veri akışı öneki (`.ds-test-…`) atılır.
    /// İlk parça bilinen bir ortam değilse (ya da index yoksa) `nil`.
    static func environment(fromIndex index: String) -> String? {
        var name = index.lowercased()
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        if name.hasPrefix(".ds-") { name = String(name.dropFirst(4)) }
        guard let first = name.split(separator: "-").first, knownEnvironments.contains(String(first)) else { return nil }
        return String(first)
    }

    /// Yol ve sorgu ayrılır; logdaki `?=` gibi adı boş parçalar atılır.
    static func splitPath(_ raw: String) -> (String, [KeyValueEntry]) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let questionMark = trimmed.firstIndex(of: "?") else {
            return (trimmed, [])
        }
        let path = String(trimmed[..<questionMark])
        var components = URLComponents()
        components.percentEncodedQuery = String(trimmed[trimmed.index(after: questionMark)...])
        let query = (components.queryItems ?? [])
            .filter { !$0.name.isEmpty }
            .map { KeyValueEntry(key: $0.name, value: $0.value ?? "") }
        return (path, query)
    }

    /// `_source` öncelikli; yoksa `fields` (değerler tek elemanlı dizi).
    private struct Fields {
        let source: [String: Any]?
        let fields: [String: Any]?

        init(document: [String: Any]) {
            source = document["_source"] as? [String: Any]
            fields = document["fields"] as? [String: Any]
        }

        func string(_ key: String) -> String? {
            if let value = source?[key] { return Self.text(value) }
            if let array = fields?[key] as? [Any], let first = array.first { return Self.text(first) }
            return nil
        }

        func headers() -> [(name: String, value: String)] {
            if let headers = source?["headers"] as? [String: Any] {
                return headers.compactMap { key, value in Self.text(value).map { (key, $0) } }
            }
            // fields: "headers.x-ad" ve kopyası "headers.x-ad.keyword".
            return (fields ?? [:]).compactMap { key, value in
                guard key.hasPrefix("headers."), !key.hasSuffix(".keyword"),
                      let first = (value as? [Any])?.first, let text = Self.text(first) else { return nil }
                return (String(key.dropFirst("headers.".count)), text)
            }
        }

        private static func text(_ value: Any) -> String? {
            switch value {
            case let string as String: return string
            case let number as NSNumber: return number.stringValue
            case let array as [Any]: return array.first.flatMap(text)
            default: return nil
            }
        }
    }

    // MARK: - İstek oluşturma

    public struct Options: Sendable {
        /// Metot, adres ve sorgu.
        public var includeURL = true
        public var includeHeaders = true
        public var includeBody = true
        /// Alınacak başlıkların `id`'leri. "Her zaman atılır" grubu seçilse de alınmaz.
        public var selectedHeaders: Set<String>

        public init(selectedHeaders: Set<String>) {
            self.selectedHeaders = selectedHeaders
        }
    }

    public struct Output: Sendable {
        public let request: RequestModel
        /// Vault'a yazılacak token/cookie değerleri; istekte yalnızca referans kalır.
        public let secrets: [(name: String, value: String)]
    }

    /// - Parameter base: Doluysa seçilen bölümler bu isteğin üzerine yazılır;
    ///   seçilmeyen bölümler (ve auth, ayarlar) olduğu gibi kalır.
    public static func build(_ entry: Entry, options: Options, onto base: RequestModel? = nil) -> Output {
        var request = base ?? RequestModel(name: defaultName(for: entry))
        var secrets: [(name: String, value: String)] = []

        if options.includeURL {
            request.method = entry.method
            request.url = entry.urlTemplate
            request.queryParams = entry.query
        }
        if options.includeBody, let body = entry.body {
            let contentType = entry.headers.first { $0.id == "content-type" }?.value
                ?? (isJSON(body) ? "application/json" : "text/plain")
            let pretty = isJSON(body) ? Beautifier.beautifiedOrOriginal(body, as: .json) : body
            request.body = .raw(content: pretty, contentType: contentType)
        }
        if options.includeHeaders {
            for header in entry.headers where header.category != .dropped && options.selectedHeaders.contains(header.id) {
                var value = header.value
                if header.sensitiveKind == .credential {
                    let name = secretName(for: header, in: entry)
                    secrets.append((name, header.value))
                    value = "{{secret:\(name)}}"
                }
                request.headers.removeAll { $0.key.lowercased() == header.id }
                request.headers.append(KeyValueEntry(key: header.name, value: value))
            }
        }
        return Output(request: request, secrets: secrets)
    }

    /// Aynı servisin aynı başlığı her içe aktarmada aynı secret'ı günceller:
    /// logdan yeni token almak, eskisini yenilemek demektir.
    public static func secretName(for header: ClassifiedHeader, in entry: Entry) -> String {
        "\(entry.serviceName).\(header.id)"
    }

    static func defaultName(for entry: Entry) -> String {
        let segments = entry.path.split(separator: "/").suffix(2)
        return segments.isEmpty ? entry.serviceName : segments.joined(separator: "/")
    }

    private static func isJSON(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }
}
