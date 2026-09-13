import Foundation

/// Koleksiyon içe/dışa aktarma: BoltDock'ın kendi formatı ve Postman v2.1.
public enum CollectionPorting {
    public struct ImportOutcome {
        public let collection: CollectionModel
        public let wasRenamed: Bool
        public let warnings: [String]
    }

    public enum PortingError: Error, LocalizedError {
        case invalidFormat(String)
        case nameConflictUnresolved(String)

        public var errorDescription: String? {
            switch self {
            case .invalidFormat(let detail):
                return "Dosya tanınamadı: \(detail)"
            case .nameConflictUnresolved(let name):
                return "\"\(name)\" için uygun bir isim bulunamadı — çok fazla kopya var. Mevcut koleksiyonları yeniden adlandırıp tekrar dene."
            }
        }
    }

    private static let acceptedFormats: Set<String> = ["boltdock-collection", "vaultman-collection"]

    /// Dışa aktarma zarfı: format alanı sayesinde import'ta dosya güvenle tanınır.
    private struct Envelope: Codable {
        var format: String
        var version: Int
        var collection: CollectionModel
    }

    // MARK: - Export

    public static func exportData(_ collection: CollectionModel) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(format: "boltdock-collection", version: 1, collection: collection))
    }

    // MARK: - BoltDock import

    public static func importBoltDock(_ data: Data, existingNames: [String]) throws -> ImportOutcome {
        let decoder = JSONDecoder()
        let collection: CollectionModel
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            // "vaultman-collection": uygulama adı değişmeden önce dışa
            // aktarılmış dosyalar da okunabilsin.
            guard Self.acceptedFormats.contains(envelope.format) else {
                throw PortingError.invalidFormat("beklenen format boltdock-collection, gelen: \(envelope.format)")
            }
            collection = envelope.collection
        } else if let bare = try? decoder.decode(CollectionModel.self, from: data) {
            collection = bare
        } else {
            throw PortingError.invalidFormat("geçerli bir BoltDock koleksiyon JSON'u değil")
        }
        let (name, renamed) = try resolveName(collection.name, suffix: "New", existingNames: existingNames)
        return ImportOutcome(
            collection: regenerateIDs(collection, name: name),
            wasRenamed: renamed,
            warnings: []
        )
    }

    // MARK: - Postman import

    public static func importPostman(_ data: Data, existingNames: [String]) throws -> ImportOutcome {
        // Postman API yanıtı koleksiyonu {"collection": {...}} zarfında döner;
        // export dosyası ise doğrudan koleksiyondur. İkisi de kabul edilir.
        struct APIWrapper: Decodable {
            let collection: PostmanCollection
        }
        let decoder = JSONDecoder()
        let postman: PostmanCollection
        if let wrapper = try? decoder.decode(APIWrapper.self, from: data) {
            postman = wrapper.collection
        } else if let direct = try? decoder.decode(PostmanCollection.self, from: data) {
            postman = direct
        } else {
            throw PortingError.invalidFormat("geçerli bir Postman v2.x koleksiyonu değil")
        }

        var warnings: [String] = []
        var requests: [RequestModel] = []
        flatten(items: postman.item ?? [], prefix: "", into: &requests, warnings: &warnings)

        if requests.isEmpty {
            warnings.append("Koleksiyonda dönüştürülebilir istek bulunamadı.")
        }
        let (name, renamed) = try resolveName(
            postman.info.name ?? "Postman Koleksiyonu",
            suffix: "fromPostman",
            existingNames: existingNames
        )
        return ImportOutcome(
            collection: CollectionModel(name: name, requests: requests),
            wasRenamed: renamed,
            warnings: warnings
        )
    }

    // MARK: - Ortak yardımcılar

    /// İsim çakışmasını çözer: önce "isim <suffix>", o da doluysa "isim <suffix> 2..50".
    /// Hepsi doluysa hata — kullanıcıya bildirilmeli.
    public static func resolveName(_ base: String, suffix: String, existingNames: [String]) throws -> (String, Bool) {
        let existing = Set(existingNames)
        guard existing.contains(base) else { return (base, false) }
        let candidate = "\(base) \(suffix)"
        guard existing.contains(candidate) else { return (candidate, true) }
        for index in 2...50 {
            let numbered = "\(candidate) \(index)"
            if !existing.contains(numbered) { return (numbered, true) }
        }
        throw PortingError.nameConflictUnresolved(base)
    }

    /// İçe aktarılan koleksiyona yeni UUID'ler verir; mevcut workspace'teki
    /// kayıtlarla ID çakışması yaşanmaz.
    private static func regenerateIDs(_ collection: CollectionModel, name: String) -> CollectionModel {
        var copy = collection
        copy.id = UUID()
        copy.name = name
        copy.requests = copy.requests.map { request in
            var fresh = request
            fresh.id = UUID()
            return fresh
        }
        return copy
    }

    private static func flatten(
        items: [PostmanCollection.Item],
        prefix: String,
        into requests: inout [RequestModel],
        warnings: inout [String]
    ) {
        for item in items {
            if let children = item.item {
                // Klasörler düzleştirilir; isim "Klasör / İstek" olur.
                let folder = item.name ?? "Klasör"
                if prefix.isEmpty, !warnings.contains(where: { $0.contains("Klasörler") }) {
                    warnings.append("Klasörler desteklenmiyor; istek adları \"Klasör / İstek\" olarak düzleştirildi.")
                }
                flatten(items: children, prefix: prefix.isEmpty ? folder : "\(prefix) / \(folder)",
                        into: &requests, warnings: &warnings)
                continue
            }
            guard let pmRequest = item.request else { continue }
            let baseName = item.name ?? "İsimsiz İstek"
            let name = prefix.isEmpty ? baseName : "\(prefix) / \(baseName)"
            requests.append(convert(pmRequest, name: name, warnings: &warnings))
        }
    }

    private static func convert(
        _ pm: PostmanCollection.PMRequest,
        name: String,
        warnings: inout [String]
    ) -> RequestModel {
        var model = RequestModel(name: name)

        if let methodText = pm.method?.uppercased() {
            if let method = HTTPMethod(rawValue: methodText) {
                model.method = method
            } else {
                warnings.append("\"\(name)\": desteklenmeyen metot \(methodText), GET'e çevrildi.")
            }
        }
        model.url = pm.url?.raw ?? ""
        model.headers = (pm.header ?? []).compactMap { header in
            guard let key = header.key else { return nil }
            return KeyValueEntry(key: key, value: header.value ?? "", enabled: !(header.disabled ?? false))
        }
        model.body = convertBody(pm.body, requestName: name, warnings: &warnings)
        model.auth = convertAuth(pm.auth, requestName: name, warnings: &warnings)
        return model
    }

    private static func convertBody(
        _ body: PostmanCollection.PMBody?,
        requestName: String,
        warnings: inout [String]
    ) -> RequestBody {
        guard let body, let mode = body.mode else { return .none }
        switch mode {
        case "raw":
            let language = body.options?.raw?.language?.lowercased() ?? "text"
            let contentType: String
            switch language {
            case "json": contentType = "application/json"
            case "xml": contentType = "application/xml"
            case "html": contentType = "text/html"
            case "javascript": contentType = "application/javascript"
            default: contentType = "text/plain"
            }
            return .raw(content: body.raw ?? "", contentType: contentType)
        case "urlencoded":
            return .formURLEncoded(fields: (body.urlencoded ?? []).compactMap { field in
                guard let key = field.key else { return nil }
                return KeyValueEntry(key: key, value: field.value ?? "", enabled: !(field.disabled ?? false))
            })
        case "formdata":
            var fields: [KeyValueEntry] = []
            for field in body.formdata ?? [] {
                guard let key = field.key else { continue }
                if field.type == "file" {
                    warnings.append("\"\(requestName)\": dosya tipli form alanı \"\(key)\" atlandı (dosya desteği yok).")
                    continue
                }
                fields.append(KeyValueEntry(key: key, value: field.value ?? "", enabled: !(field.disabled ?? false)))
            }
            return .multipartForm(fields: fields)
        default:
            warnings.append("\"\(requestName)\": desteklenmeyen body tipi \"\(mode)\", body boş bırakıldı.")
            return .none
        }
    }

    private static func convertAuth(
        _ auth: PostmanCollection.PMAuth?,
        requestName: String,
        warnings: inout [String]
    ) -> AuthConfig {
        guard let auth, let type = auth.type, type != "noauth" else { return .none }
        func value(_ entries: [PostmanCollection.PMKV]?, _ key: String) -> String? {
            entries?.first { $0.key == key }?.value
        }
        switch type {
        case "bearer":
            return .bearer(token: value(auth.bearer, "token") ?? "")
        case "basic":
            return .basic(
                username: value(auth.basic, "username") ?? "",
                password: value(auth.basic, "password") ?? ""
            )
        case "apikey":
            let location: AuthConfig.APIKeyLocation = value(auth.apikey, "in") == "query" ? .queryParam : .header
            return .apiKey(
                key: value(auth.apikey, "key") ?? "X-Api-Key",
                value: value(auth.apikey, "value") ?? "",
                location: location
            )
        default:
            warnings.append("\"\(requestName)\": desteklenmeyen auth tipi \"\(type)\", Auth Yok olarak ayarlandı.")
            return .none
        }
    }
}

// MARK: - Postman v2.x şeması (toleranslı, kısmi)

private struct PostmanCollection: Decodable {
    struct Info: Decodable {
        let name: String?
        let schema: String?
    }

    struct Item: Decodable {
        let name: String?
        let item: [Item]?
        let request: PMRequest?
    }

    struct PMRequest: Decodable {
        let method: String?
        let url: PMUrl?
        let header: [PMHeader]?
        let body: PMBody?
        let auth: PMAuth?
    }

    /// Postman url alanı düz string ya da {raw: "..."} objesi olabilir.
    struct PMUrl: Decodable {
        let raw: String?

        private enum CodingKeys: String, CodingKey { case raw }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self) {
                self.raw = text
            } else {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.raw = try container.decodeIfPresent(String.self, forKey: .raw)
            }
        }
    }

    struct PMHeader: Decodable {
        let key: String?
        let value: String?
        let disabled: Bool?
    }

    struct PMBody: Decodable {
        let mode: String?
        let raw: String?
        let urlencoded: [PMField]?
        let formdata: [PMFormField]?
        let options: PMOptions?

        struct PMOptions: Decodable {
            struct RawOptions: Decodable { let language: String? }
            let raw: RawOptions?
        }
    }

    struct PMField: Decodable {
        let key: String?
        let value: String?
        let disabled: Bool?
    }

    struct PMFormField: Decodable {
        let key: String?
        let value: String?
        let type: String?
        let disabled: Bool?
    }

    struct PMAuth: Decodable {
        let type: String?
        let bearer: [PMKV]?
        let basic: [PMKV]?
        let apikey: [PMKV]?
    }

    /// Auth girdilerinde value string/bool/sayı olabilir; hepsi string'e çevrilir.
    struct PMKV: Decodable {
        let key: String?
        let value: String?

        private enum CodingKeys: String, CodingKey { case key, value }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.key = try container.decodeIfPresent(String.self, forKey: .key)
            if let text = try? container.decode(String.self, forKey: .value) {
                self.value = text
            } else if let flag = try? container.decode(Bool.self, forKey: .value) {
                self.value = String(flag)
            } else if let number = try? container.decode(Double.self, forKey: .value) {
                self.value = number.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int(number))
                    : String(number)
            } else {
                self.value = nil
            }
        }
    }

    let info: Info
    let item: [Item]?
}
