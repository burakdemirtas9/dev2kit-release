import Foundation

/// Koleksiyonu Postman Collection v2.1 biçiminde dışa aktarır: istekler ve
/// kayıtlı response örnekleri (`response[]`, `originalRequest` dahil).
///
/// Postman'de karşılığı olmayan parçalar sessizce atılmaz, not olarak döner
/// (OAuth2 yapılandırması, metin olmayan örnek body'si, istek ayarları).
/// Secret'lar çözülmez: `{{secret:ad}}` referansı olduğu gibi yazılır
/// (dev2kit dışa aktarımıyla aynı kural; değer hiçbir dosyaya girmez).
public enum PostmanExporter {
    public static let schemaURL = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"

    public struct Output {
        public let data: Data
        /// Kullanıcıya gösterilecek kayıp/dönüşüm notları.
        public let notes: [String]
    }

    public static func export(_ collection: CollectionModel) throws -> Output {
        var notes = Notes()
        let items: [[String: Any]] = collection.requests.map { request in
            var item: [String: Any] = [
                "name": request.name,
                "request": requestObject(
                    method: request.method, url: request.url, headers: request.headers,
                    queryParams: request.queryParams, body: request.body,
                    auth: request.auth, context: request.name, notes: &notes
                ),
            ]
            let responses = request.examples.map { example(request: request, $0, notes: &notes) }
            item["response"] = responses
            if request.options != .default { notes.add(.options, request.name) }
            return item
        }
        let root: [String: Any] = [
            "info": [
                "_postman_id": collection.id.uuidString.lowercased(),
                "name": collection.name,
                "schema": schemaURL,
            ],
            "item": items,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return Output(data: data, notes: notes.messages)
    }

    // MARK: - İstek

    static func requestObject(
        method: HTTPMethod,
        url: String,
        headers: [KeyValueEntry],
        queryParams: [KeyValueEntry],
        body: RequestBody,
        auth: AuthConfig,
        context: String,
        notes: inout Notes
    ) -> [String: Any] {
        var headerList = headers.filter { !$0.key.isEmpty }.map(keyValue)
        // Ham gövdenin türü Postman'de "dil" ile ifade ediliyor; karşılığı
        // olmayan tür (ör. application/x-yaml) kaybolmasın diye açık header.
        if case .raw(_, let contentType) = body, language(forContentType: contentType) == nil,
           !contentType.isEmpty,
           !headers.contains(where: { $0.key.trimmingCharacters(in: .whitespaces).lowercased() == "content-type" }) {
            headerList.append(["key": "Content-Type", "value": contentType, "type": "text"])
        }
        var object: [String: Any] = [
            "method": method.rawValue,
            "header": headerList,
            // Adres düz metin: Postman bunu ayrıştırır. Kapalı query
            // parametreleri adreste olmadığı için taşınmaz (not).
            "url": url,
        ]
        if queryParams.contains(where: { !$0.enabled && !$0.key.isEmpty }) { notes.add(.disabledQuery, context) }
        if let bodyObject = bodyObject(body) { object["body"] = bodyObject }
        if let authObject = authObject(auth, context: context, notes: &notes) { object["auth"] = authObject }
        return object
    }

    static func keyValue(_ entry: KeyValueEntry) -> [String: Any] {
        var object: [String: Any] = ["key": entry.key, "value": entry.value, "type": "text"]
        if !entry.enabled { object["disabled"] = true }
        return object
    }

    static func bodyObject(_ body: RequestBody) -> [String: Any]? {
        switch body {
        case .none:
            return nil
        case .raw(let content, let contentType):
            return [
                "mode": "raw",
                "raw": content,
                "options": ["raw": ["language": language(forContentType: contentType) ?? "text"]],
            ]
        case .formURLEncoded(let fields):
            return ["mode": "urlencoded", "urlencoded": fields.filter { !$0.key.isEmpty }.map(keyValue)]
        case .multipartForm(let fields):
            return ["mode": "formdata", "formdata": fields.filter { !$0.key.isEmpty }.map(keyValue)]
        }
    }

    /// İçe aktarmanın (`CollectionPorting.convertBody`) tersi.
    static func language(forContentType contentType: String) -> String? {
        let type = contentType.lowercased()
        if type.contains("json") { return "json" }
        if type.contains("xml") { return "xml" }
        if type.contains("html") { return "html" }
        if type.contains("javascript") { return "javascript" }
        if type.hasPrefix("text/plain") { return "text" }
        return nil
    }

    static func authObject(_ auth: AuthConfig, context: String, notes: inout Notes) -> [String: Any]? {
        func entry(_ key: String, _ value: String) -> [String: Any] { ["key": key, "value": value, "type": "string"] }
        switch auth {
        case .none:
            return nil
        case .bearer(let token):
            return ["type": "bearer", "bearer": [entry("token", token)]]
        case .basic(let username, let password):
            return ["type": "basic", "basic": [entry("username", username), entry("password", password)]]
        case .apiKey(let key, let value, let location):
            return ["type": "apikey", "apikey": [
                entry("key", key), entry("value", value),
                entry("in", location == .queryParam ? "query" : "header"),
            ]]
        case .oauth2:
            // Postman'in OAuth2 yapılandırması farklı; yarım çeviri yerine yok.
            notes.add(.oauth2, context)
            return nil
        }
    }

    // MARK: - Örnek

    static func example(request: RequestModel, _ example: ResponseExample, notes: inout Notes) -> [String: Any] {
        let context = "\(request.name) › \(example.name)"
        var object: [String: Any] = [
            "name": example.name,
            "header": example.headers.filter { !$0.name.isEmpty }.map { header -> [String: Any] in
                var value: [String: Any] = ["key": header.name, "value": header.value]
                if !header.enabled { value["disabled"] = true }
                return value
            },
            "cookie": [] as [Any],
        ]
        if example.statusCode > 0 {
            object["code"] = example.statusCode
            object["status"] = HTTPStatus.reasonPhrase(example.statusCode) ?? ""
        }
        switch example.bodyEncoding {
        case .text:
            object["body"] = example.body
            object["_postman_previewlanguage"] = language(forContentType: example.contentType ?? "") ?? "text"
        case .base64:
            // Postman örnek body'si metin; ikili içerik taşınamaz.
            notes.add(.binaryExample, context)
        }
        if let original = example.request {
            var ignored = Notes()
            object["originalRequest"] = requestObject(
                method: original.method, url: original.url, headers: original.headers,
                queryParams: original.queryParams, body: original.body,
                auth: .none, context: context, notes: &ignored
            )
        }
        return object
    }

    // MARK: - Notlar

    struct Notes {
        enum Kind: CaseIterable { case oauth2, binaryExample, disabledQuery, options }
        private var places: [Kind: [String]] = [:]

        mutating func add(_ kind: Kind, _ place: String) {
            if places[kind]?.contains(place) != true { places[kind, default: []].append(place) }
        }

        var messages: [String] {
            Kind.allCases.compactMap { kind in
                guard let list = places[kind], !list.isEmpty else { return nil }
                let shown = list.prefix(5).map { "“\($0)”" }.joined(separator: ", ")
                let more = list.count > 5 ? " " + L10n.plural("postmanExport.more", count: list.count - 5) : ""
                switch kind {
                case .oauth2: return L10n.t("postmanExport.oauth2", shown + more)
                case .binaryExample: return L10n.t("postmanExport.binaryExample", shown + more)
                case .disabledQuery: return L10n.t("postmanExport.disabledQuery", shown + more)
                case .options: return L10n.t("postmanExport.options", shown + more)
                }
            }
        }
    }
}
