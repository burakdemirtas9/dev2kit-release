import Foundation

/// OpenAPI 3.x ve Swagger 2.0 (JSON) dokümanından koleksiyon oluşturur.
///
/// Doküman dışarıdan gelir, güvenilmez sayılır: hiçbir şey çalıştırılmaz,
/// `$ref` yalnızca doküman içinde (`#/...`) çözülür, özyineleme ve boyut
/// sınırlıdır. Oluşan koleksiyon içe aktarmadan önce `ImportReviewer`'dan geçer.
///
/// İstek adresleri `{{değişken}}/yol` biçimindedir; değişkenin değeri
/// dokümandaki sunucu adresidir ve environment'a yazılır. Böylece aynı
/// koleksiyon farklı ortamlarda yalnızca değişken değiştirilerek kullanılır.
public enum OpenAPIImporter {
    public enum ImportError: Error, LocalizedError, Equatable {
        case notJSON
        case yaml
        case notOpenAPI
        case noOperations

        public var errorDescription: String? {
            switch self {
            case .notJSON: return L10n.t("openapi.notJSON")
            case .yaml: return L10n.t("openapi.yaml")
            case .notOpenAPI: return L10n.t("openapi.notOpenAPI")
            case .noOperations: return L10n.t("openapi.noOperations")
            }
        }
    }

    /// Kullanıcıya önizlemede gösterilenler.
    public struct Document {
        let root: [String: Any]
        public let title: String
        public let version: String?
        public let specVersion: String
        /// Mutlak sunucu adresi (göreli adresler dokümanın alındığı adrese göre çözülür).
        public let serverURL: String?
        public let operationCount: Int
        public let sourceURL: URL?
        /// Adres değişkeni ve koleksiyon için önerilen ad.
        public let suggestedName: String

        var isSwagger2: Bool { specVersion.hasPrefix("2") }
    }

    static let methods = ["get", "put", "post", "delete", "patch", "head", "options"]
    /// Başlıkta "API" gibi anlamsız başlıklar yerine adres kullanılır. Springdoc'un
    /// varsayılan başlığı "OpenAPI definition"dır.
    static let genericTitles: Set<String> = ["openapi definition", "api", "swagger", "api documentation", "rest api"]

    // MARK: - Çözümleme

    public static func parse(_ data: Data, sourceURL: URL?) throws -> Document {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            let head = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if head.hasPrefix("openapi:") || head.hasPrefix("swagger:") { throw ImportError.yaml }
            throw ImportError.notJSON
        }
        guard let root = object as? [String: Any] else { throw ImportError.notOpenAPI }
        let specVersion = (root["openapi"] as? String) ?? (root["swagger"] as? String)
        guard let specVersion else { throw ImportError.notOpenAPI }

        let info = root["info"] as? [String: Any] ?? [:]
        let rawTitle = (info["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let operationCount = (root["paths"] as? [String: Any] ?? [:]).values.reduce(0) { count, item in
            count + ((item as? [String: Any]).map { item in methods.filter { item[$0] is [String: Any] }.count } ?? 0)
        }
        guard operationCount > 0 else { throw ImportError.noOperations }

        let server = serverURL(root: root, specVersion: specVersion, sourceURL: sourceURL)
        return Document(
            root: root,
            title: rawTitle.isEmpty ? "OpenAPI" : rawTitle,
            version: info["version"] as? String,
            specVersion: specVersion,
            serverURL: server,
            operationCount: operationCount,
            sourceURL: sourceURL,
            suggestedName: suggestedName(title: rawTitle, serverURL: server, serverPath: serverPath(root: root), sourceURL: sourceURL)
        )
    }

    /// OAS3 `servers[0]` (değişkenler varsayılanlarıyla) ya da Swagger 2 `schemes/host/basePath`.
    static func serverURL(root: [String: Any], specVersion: String, sourceURL: URL?) -> String? {
        let origin = sourceURL.flatMap { url -> String? in
            guard let scheme = url.scheme, let host = url.host else { return nil }
            return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
        }
        if specVersion.hasPrefix("2") {
            let schemes = root["schemes"] as? [String] ?? []
            let scheme = schemes.contains("https") ? "https" : (schemes.first ?? sourceURL?.scheme ?? "https")
            let basePath = (root["basePath"] as? String).map { $0 == "/" ? "" : $0 } ?? ""
            if let host = root["host"] as? String, !host.isEmpty {
                return "\(scheme)://\(host)\(basePath)"
            }
            return origin.map { "\($0)\(basePath)" }
        }
        guard let server = (root["servers"] as? [[String: Any]])?.first,
              var url = server["url"] as? String else { return origin }
        for (name, value) in server["variables"] as? [String: Any] ?? [:] {
            if let defaultValue = (value as? [String: Any])?["default"] as? String {
                url = url.replacingOccurrences(of: "{\(name)}", with: defaultValue)
            }
        }
        if url.hasSuffix("/") { url.removeLast() }
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        // Göreli sunucu ("/", "/api"): dokümanın alındığı adrese göre.
        return origin.map { "\($0)\(url.hasPrefix("/") || url.isEmpty ? url : "/\(url)")" }
    }

    /// Göreli sunucu yolu (`"/fx-bff-service"`, Swagger 2 `basePath`). Adres
    /// olmadan (yapıştırılan JSON) mutlak adres çıkmaz ama ad için işe yarar.
    static func serverPath(root: [String: Any]) -> String? {
        let raw = ((root["servers"] as? [[String: Any]])?.first?["url"] as? String) ?? (root["basePath"] as? String)
        return raw.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    static func suggestedName(title: String, serverURL: String?, serverPath: String? = nil, sourceURL: URL?) -> String {
        if !genericTitles.contains(title.lowercased()), !slug(title).isEmpty {
            return slug(title)
        }
        // Gateway arkasında servis adı genelde yolun ilk parçasıdır: /fx-bff-service/v3/api-docs
        let ignored: Set<String> = ["v1", "v2", "v3", "api", "api-docs", "swagger-ui", "openapi.json", "swagger.json", "index.html"]
        let pathSource = serverPath.flatMap { URL(string: "http://yer-tutucu\($0)") }
        for url in [serverURL.flatMap(URL.init(string:)), pathSource, sourceURL].compactMap({ $0 }) {
            if let first = url.pathComponents.first(where: { $0 != "/" && !ignored.contains($0.lowercased()) }) {
                return slug(first)
            }
        }
        let host = (serverURL.flatMap(URL.init(string:)) ?? sourceURL)?.host ?? ""
        let label = slug(host.split(separator: ".").first.map(String.init) ?? "")
        return label.isEmpty ? "api" : label
    }

    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ı", with: "i")
        var result = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Koleksiyon oluşturma

    public static func makeCollection(
        from document: Document,
        variableName: String,
        existingNames: [String]
    ) throws -> CollectionPorting.ImportOutcome {
        var builder = Builder(document: document, variableName: variableName)
        let requests = builder.buildRequests()
        let base = document.title.lowercased() == "openapi" || genericTitles.contains(document.title.lowercased())
            ? document.suggestedName
            : document.title
        let (name, renamed) = try CollectionPorting.resolveName(base, suffix: "(OpenAPI)", existingNames: existingNames)
        return CollectionPorting.ImportOutcome(
            collection: CollectionModel(name: name, requests: requests),
            wasRenamed: renamed,
            warnings: builder.notes(serverURL: document.serverURL, sourceURL: document.sourceURL)
        )
    }

    /// Dokümanı dolaşıp istekleri kurar; atlanan içerik için not toplar.
    struct Builder {
        let document: Document
        let variableName: String
        private var skippedFileFields = 0
        private var skippedCookieParams = 0
        private var usedSchemes: [String: String] = [:]
        private var tokenURLs: Set<String> = []

        init(document: Document, variableName: String) {
            self.document = document
            self.variableName = variableName
        }

        private var root: [String: Any] { document.root }

        mutating func buildRequests() -> [RequestModel] {
            let paths = root["paths"] as? [String: Any] ?? [:]
            var requests: [(sortKey: String, request: RequestModel)] = []
            for path in paths.keys.sorted() {
                guard let item = paths[path] as? [String: Any] else { continue }
                let shared = item["parameters"] as? [Any] ?? []
                for (index, method) in OpenAPIImporter.methods.enumerated() {
                    guard let operation = item[method] as? [String: Any] else { continue }
                    let request = buildRequest(path: path, method: method, operation: operation, sharedParameters: shared)
                    let tag = (operation["tags"] as? [String])?.first ?? "~"
                    requests.append(("\(tag)\u{0}\(path)\u{0}\(index)", request))
                }
            }
            return requests.sorted { $0.sortKey < $1.sortKey }.map(\.request)
        }

        private mutating func buildRequest(
            path: String,
            method: String,
            operation: [String: Any],
            sharedParameters: [Any]
        ) -> RequestModel {
            var name = (operation["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (operation["operationId"] as? String)
                ?? "\(method.uppercased()) \(path)"
            if let tag = (operation["tags"] as? [String])?.first, !tag.isEmpty { name = "\(tag) / \(name)" }
            if operation["deprecated"] as? Bool == true { name += " (deprecated)" }

            var request = RequestModel(
                name: name,
                method: HTTPMethod(rawValue: method.uppercased()) ?? .get,
                // Yol parametreleri {id} → {{id}}: değer environment'tan ya da elle girilir.
                url: "{{\(variableName)}}" + path.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
            )

            var parameters: [String: [String: Any]] = [:]
            for raw in sharedParameters + (operation["parameters"] as? [Any] ?? []) {
                guard let parameter = resolve(raw), let pName = parameter["name"] as? String, let place = parameter["in"] as? String else { continue }
                parameters["\(place):\(pName)"] = parameter
            }
            var formParameters: [[String: Any]] = []
            for key in parameters.keys.sorted() {
                let parameter = parameters[key]!
                let pName = parameter["name"] as? String ?? ""
                let required = parameter["required"] as? Bool ?? false
                let value = parameterValue(parameter)
                switch parameter["in"] as? String {
                case "query":
                    request.queryParams.append(KeyValueEntry(key: pName, value: value, enabled: required))
                case "header":
                    guard !["authorization", "content-type", "accept"].contains(pName.lowercased()) else { continue }
                    request.headers.append(KeyValueEntry(key: pName, value: value, enabled: required))
                case "cookie":
                    skippedCookieParams += 1
                case "body":
                    if let schema = parameter["schema"] { request.body = jsonBody(sample(schema, depth: 0, seen: [])) }
                case "formData":
                    formParameters.append(parameter)
                default:
                    break
                }
            }
            if !formParameters.isEmpty { request.body = formBody(formParameters, consumes: operation["consumes"] ?? root["consumes"]) }
            if let requestBody = operation["requestBody"].flatMap(resolve) {
                request.body = openAPI3Body(requestBody)
            }
            if case .raw(_, let contentType) = request.body {
                request.headers.append(KeyValueEntry(key: "Content-Type", value: contentType))
            }
            request.auth = auth(for: operation)
            return request
        }

        // MARK: Parametreler ve gövde

        private func parameterValue(_ parameter: [String: Any]) -> String {
            if let example = parameter["example"] { return text(example) }
            if let examples = parameter["examples"] as? [String: Any],
               let first = examples.keys.sorted().first,
               let value = (resolve(examples[first] as Any))?["value"] {
                return text(value)
            }
            let schema = parameter["schema"].flatMap(resolve) ?? parameter
            if let value = schema["example"] ?? schema["default"] ?? (schema["enum"] as? [Any])?.first { return text(value) }
            return ""
        }

        private mutating func openAPI3Body(_ requestBody: [String: Any]) -> RequestBody {
            let content = requestBody["content"] as? [String: Any] ?? [:]
            let types = content.keys.sorted()
            let chosen = types.first { $0.contains("json") }
                ?? types.first { $0 == "application/x-www-form-urlencoded" }
                ?? types.first { $0 == "multipart/form-data" }
                ?? types.first
            guard let type = chosen, let media = content[type] as? [String: Any] else { return .none }

            let example: Any? = media["example"]
                ?? (media["examples"] as? [String: Any]).flatMap { examples in
                    examples.keys.sorted().first.flatMap { resolve(examples[$0] as Any)?["value"] }
                }
            let value = example ?? media["schema"].map { sample($0, depth: 0, seen: []) }

            if type == "application/x-www-form-urlencoded" || type == "multipart/form-data" {
                let schema = media["schema"].flatMap(resolve) ?? [:]
                var fields: [KeyValueEntry] = []
                for (key, property) in (schema["properties"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    let resolved = resolve(property) ?? [:]
                    if resolved["format"] as? String == "binary" { skippedFileFields += 1; continue }
                    fields.append(KeyValueEntry(key: key, value: text(sample(resolved, depth: 1, seen: []))))
                }
                return type == "multipart/form-data" ? .multipartForm(fields: fields) : .formURLEncoded(fields: fields)
            }
            if type.contains("json") { return jsonBody(value, contentType: type) }
            return .raw(content: value.map(text) ?? "", contentType: type)
        }

        private mutating func formBody(_ parameters: [[String: Any]], consumes: Any?) -> RequestBody {
            let multipart = (consumes as? [String])?.contains("multipart/form-data") == true
                || parameters.contains { $0["type"] as? String == "file" }
            var fields: [KeyValueEntry] = []
            for parameter in parameters {
                if parameter["type"] as? String == "file" { skippedFileFields += 1; continue }
                fields.append(KeyValueEntry(key: parameter["name"] as? String ?? "", value: parameterValue(parameter)))
            }
            return multipart ? .multipartForm(fields: fields) : .formURLEncoded(fields: fields)
        }

        private func jsonBody(_ value: Any?, contentType: String = "application/json") -> RequestBody {
            guard let value else { return .none }
            let text: String
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                text = String(decoding: data, as: UTF8.self)
            } else {
                text = self.text(value)
            }
            return .raw(content: text, contentType: contentType)
        }

        // MARK: Örnek üretimi

        /// Şemadan örnek değer. Döngüsel `$ref` ve derinlik sınırlıdır.
        func sample(_ raw: Any, depth: Int, seen: Set<String>) -> Any {
            guard depth < 8, var schema = raw as? [String: Any] else { return [String: Any]() }
            var seen = seen
            if let ref = schema["$ref"] as? String {
                guard !seen.contains(ref), let target = lookup(ref) else { return [String: Any]() }
                seen.insert(ref)
                schema = target
            }
            if let value = schema["example"] ?? schema["default"] ?? (schema["enum"] as? [Any])?.first { return value }
            if let parts = schema["allOf"] as? [Any] {
                var merged: [String: Any] = [:]
                for part in parts {
                    if let object = sample(part, depth: depth + 1, seen: seen) as? [String: Any] {
                        merged.merge(object) { current, _ in current }
                    }
                }
                return merged
            }
            if let first = ((schema["oneOf"] ?? schema["anyOf"]) as? [Any])?.first {
                return sample(first, depth: depth + 1, seen: seen)
            }
            let type = schema["type"] as? String ?? (schema["properties"] != nil ? "object" : "")
            switch type {
            case "object":
                var object: [String: Any] = [:]
                for (key, property) in (schema["properties"] as? [String: Any] ?? [:]).prefix(50) {
                    object[key] = sample(property, depth: depth + 1, seen: seen)
                }
                return object
            case "array":
                return schema["items"].map { [sample($0, depth: depth + 1, seen: seen)] } ?? []
            case "integer", "number":
                return 0
            case "boolean":
                return false
            case "string":
                switch schema["format"] as? String {
                case "date-time": return "2026-01-01T00:00:00Z"
                case "date": return "2026-01-01"
                case "uuid": return "00000000-0000-0000-0000-000000000000"
                case "email": return "kullanici@ornek.com"
                default: return "string"
                }
            default:
                return [String: Any]()
            }
        }

        // MARK: Auth

        private mutating func auth(for operation: [String: Any]) -> AuthConfig {
            let requirements = (operation["security"] ?? root["security"]) as? [[String: Any]] ?? []
            // Boş gereksinim listesi ya da `{}` herkese açık işlem demektir.
            guard let schemeName = requirements.first?.keys.sorted().first else { return .none }
            let schemes = document.isSwagger2
                ? root["securityDefinitions"] as? [String: Any]
                : (root["components"] as? [String: Any])?["securitySchemes"] as? [String: Any]
            guard let scheme = (schemes?[schemeName]).flatMap(resolve) else { return .none }

            let type = (scheme["type"] as? String ?? "").lowercased()
            let httpScheme = (scheme["scheme"] as? String ?? "").lowercased()
            switch (type, httpScheme) {
            case ("http", "basic"), ("basic", _):
                usedSchemes[schemeName] = L10n.t("openapi.scheme.basic")
                return .basic(username: "{{username}}", password: "{{secret:password}}")
            case ("apikey", _):
                let name = scheme["name"] as? String ?? "X-Api-Key"
                let place = scheme["in"] as? String ?? "header"
                if place == "cookie" {
                    usedSchemes[schemeName] = L10n.t("openapi.scheme.cookie")
                    return .none
                }
                usedSchemes[schemeName] = L10n.t("openapi.scheme.apiKey", name)
                return .apiKey(key: name, value: "{{secret:\(name)}}", location: place == "query" ? .queryParam : .header)
            default:
                // bearer, oauth2, openIdConnect: token {{accessToken}} değişkeninden.
                collectTokenURLs(scheme)
                usedSchemes[schemeName] = L10n.t("openapi.scheme.bearer")
                return .bearer(token: "{{accessToken}}")
            }
        }

        private mutating func collectTokenURLs(_ scheme: [String: Any]) {
            if let url = scheme["tokenUrl"] as? String { tokenURLs.insert(url) }
            for flow in (scheme["flows"] as? [String: Any] ?? [:]).values {
                if let url = (flow as? [String: Any])?["tokenUrl"] as? String { tokenURLs.insert(url) }
            }
        }

        // MARK: Notlar

        func notes(serverURL: String?, sourceURL: URL?) -> [String] {
            var notes: [String] = []
            if let serverURL {
                notes.append(L10n.t("openapi.note.server", variableName, serverURL))
            } else {
                notes.append(L10n.t("openapi.note.noServer", variableName))
            }
            if let serverHost = serverURL.flatMap(URL.init(string:))?.host?.lowercased(),
               let sourceHost = sourceURL?.host?.lowercased(), serverHost != sourceHost {
                notes.append(L10n.t("openapi.note.otherHost", sourceHost, serverHost))
            }
            let pathParams = (root["paths"] as? [String: Any] ?? [:]).keys.contains { $0.contains("{") }
            if pathParams {
                notes.append(L10n.t("openapi.note.pathParams"))
            }
            for (name, detail) in usedSchemes.sorted(by: { $0.key < $1.key }) {
                notes.append(L10n.t("openapi.note.scheme", name, detail))
            }
            if !tokenURLs.isEmpty {
                notes.append(L10n.t("openapi.note.oauth", tokenURLs.sorted().joined(separator: ", ")))
            }
            if skippedFileFields > 0 {
                notes.append(L10n.plural("openapi.note.fileFields", count: skippedFileFields))
            }
            if skippedCookieParams > 0 {
                notes.append(L10n.plural("openapi.note.cookies", count: skippedCookieParams))
            }
            return notes
        }

        // MARK: $ref

        func resolve(_ raw: Any) -> [String: Any]? {
            guard let object = raw as? [String: Any] else { return nil }
            guard let ref = object["$ref"] as? String else { return object }
            return lookup(ref)
        }

        /// Yalnızca doküman içi referanslar (`#/components/...`); dış dosya ya da
        /// adres referansı izlenmez: içe aktarma ağa kendiliğinden çıkmamalı.
        func lookup(_ ref: String) -> [String: Any]? {
            guard ref.hasPrefix("#/") else { return nil }
            var current: Any = root
            for part in ref.dropFirst(2).split(separator: "/") {
                let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let next = (current as? [String: Any])?[key] else { return nil }
                current = next
            }
            return current as? [String: Any]
        }

        private func text(_ value: Any) -> String {
            switch value {
            case let string as String: return string
            case let number as NSNumber:
                return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            default:
                if JSONSerialization.isValidJSONObject(value),
                   let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                    return String(decoding: data, as: UTF8.self)
                }
                return "\(value)"
            }
        }
    }
}
