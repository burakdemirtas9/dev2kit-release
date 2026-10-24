import Foundation

/// Koleksiyon içe/dışa aktarma: dev2kit'nın kendi formatı ve Postman v2.1.
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
                return L10n.t("porting.invalidFormat", detail)
            case .nameConflictUnresolved(let name):
                return L10n.t("porting.nameConflict", name)
            }
        }
    }

    static let currentFormat = "dev2kit-collection"

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
        return try encoder.encode(Envelope(format: currentFormat, version: 1, collection: collection))
    }

    // MARK: - dev2kit import

    public static func importDev2Kit(_ data: Data, existingNames: [String]) throws -> ImportOutcome {
        let decoder = JSONDecoder()
        let report = ExampleDecodeReport()
        decoder.userInfo[ExampleDecodeReport.key] = report
        let collection: CollectionModel
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            guard envelope.format == currentFormat else {
                throw PortingError.invalidFormat(L10n.t("porting.wrongFormat", currentFormat, envelope.format))
            }
            collection = envelope.collection
        } else if let bare = try? decoder.decode(CollectionModel.self, from: data) {
            collection = bare
        } else {
            throw PortingError.invalidFormat(L10n.t("porting.notDev2kit"))
        }
        let (name, renamed) = try resolveName(collection.name, suffix: "New", existingNames: existingNames)
        // Örnekler dışarıdan gelen veri: aynı doğrulama ve maskeleme. Bozuk
        // örnek nedeniyle not düşülür; istek ve diğer örnekler alınır.
        var warnings = report.unreadable.map { L10n.plural("example.import.unreadable", count: $0.count, $0.requestName) }
        var validated = collection
        validated.requests = collection.requests.map { request in
            let checked = ResponseExamples.validatingImported(request)
            warnings.append(contentsOf: checked.notes)
            return checked.request
        }
        return ImportOutcome(
            collection: regenerateIDs(validated, name: name),
            wasRenamed: renamed,
            warnings: warnings
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
            throw PortingError.invalidFormat(L10n.t("porting.notPostman"))
        }

        var warnings: [String] = []
        var requests: [RequestModel] = []
        flatten(items: postman.item ?? [], prefix: "", into: &requests, warnings: &warnings)

        if requests.isEmpty {
            warnings.append(L10n.t("porting.noRequests"))
        }
        // Script'ler bilinçli olarak çalıştırılmaz (içe aktarılan kod, kullanıcının
        // secret'larına erişebilirdi); ama sessizce kaybolmamalı.
        let scripts = postman.scriptCount
        if scripts > 0 {
            warnings.append(L10n.plural("porting.scripts", count: scripts))
        }
        let (name, renamed) = try resolveName(
            postman.info.name ?? L10n.t("porting.postmanName"),
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
    /// Çakışmayan ad; 50 denemede bulunamazsa orijinali döner.
    ///
    /// `resolveName`'in hata fırlatmayan sarmalayıcısı: çağıranların üçü de
    /// `(try? resolveName(...))?.0 ?? base` yazıyordu, kural tek yerde olsun.
    public static func uniqueName(_ base: String, suffix: String, existingNames: [String]) -> String {
        (try? resolveName(base, suffix: suffix, existingNames: existingNames).0) ?? base
    }

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
        // İçe aktarılan her şey normal koleksiyondur; dosyadaki işaret ikinci
        // bir "Koleksiyonsuz" ya da "Token Factory" kabı oluşturmasın.
        copy.isUngrouped = false
        copy.isTokenFactory = false
        copy.requests = copy.requests.map { request in
            var fresh = request.regeneratingExampleIDs()
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
                let folder = item.name ?? L10n.t("porting.folder")
                if prefix.isEmpty, !warnings.contains(L10n.t("porting.folders")) {
                    warnings.append(L10n.t("porting.folders"))
                }
                flatten(items: children, prefix: prefix.isEmpty ? folder : "\(prefix) / \(folder)",
                        into: &requests, warnings: &warnings)
                continue
            }
            guard let pmRequest = item.request else { continue }
            let baseName = item.name ?? L10n.t("porting.unnamed")
            let name = prefix.isEmpty ? baseName : "\(prefix) / \(baseName)"
            var request = convert(pmRequest, name: name, warnings: &warnings)
            request.examples = convertExamples(item.response, requestName: name, warnings: &warnings)
            requests.append(request)
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
                warnings.append(L10n.t("porting.badMethod", name, methodText))
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

    /// Postman'in kayıtlı response'ları (`item.response`). Bozuk ya da
    /// desteklenmeyen örnek gerçek nedeniyle not düşülerek atlanır; istek ve
    /// diğer örnekler alınır. Sınırı aşan örnek sayısı burada KIRPILMAZ:
    /// hangilerinin alınacağını kullanıcı inceleme ekranında seçer.
    private static func convertExamples(
        _ responses: LossyDecodableArray<PostmanCollection.PMResponse>?,
        requestName: String,
        warnings: inout [String]
    ) -> [ResponseExample] {
        guard let responses else { return [] }
        if responses.droppedCount > 0 {
            warnings.append(L10n.plural("example.import.unreadable", count: responses.droppedCount, requestName))
        }
        var examples: [ResponseExample] = []
        for response in responses.elements {
            let headers = (response.header ?? []).compactMap { header -> ResponseExample.Header? in
                guard let key = header.key, !(header.disabled ?? false) else { return nil }
                return ResponseExample.Header(name: key, value: header.value ?? "")
            }
            let label = response.name ?? ""
            let candidate = ResponseExample(
                name: label,
                // Kod yoksa örnek yine alınır (status doğrulanmaz).
                statusCode: response.code ?? ResponseExamples.unknownStatus,
                headers: headers,
                body: response.body ?? "",
                contentType: ResponseExamples.contentType(in: headers)
            )
            do {
                examples.append(try ResponseExamples.validatedForImport(candidate))
            } catch {
                warnings.append(L10n.t("example.import.skipped", requestName, label, error.localizedDescription))
            }
        }
        return examples
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
                    warnings.append(L10n.t("porting.fileField", requestName, key))
                    continue
                }
                fields.append(KeyValueEntry(key: key, value: field.value ?? "", enabled: !(field.disabled ?? false)))
            }
            return .multipartForm(fields: fields)
        default:
            warnings.append(L10n.t("porting.badBody", requestName, mode))
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
            warnings.append(L10n.t("porting.badAuth", requestName, type))
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
        let event: [PMEvent]?
        /// Kayıtlı response örnekleri. Tek bozuk örnek tüm dosyayı
        /// "Postman değil" saydırmasın diye eleman eleman çözülür.
        let response: LossyDecodableArray<PMResponse>?

        var scriptCount: Int {
            (event ?? []).filter(\.hasCode).count + (item ?? []).reduce(0) { $0 + $1.scriptCount }
        }
    }

    /// Pre-request / test script'i. Yalnızca varlığı sayılır; içerik okunmaz.
    struct PMEvent: Decodable {
        let script: Script?

        struct Script: Decodable {
            /// Postman `exec`'i satır dizisi ya da tek metin olarak yazabilir.
            let lines: [String]

            private enum CodingKeys: String, CodingKey { case exec }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let array = try? container.decode([String].self, forKey: .exec) {
                    lines = array
                } else if let text = try? container.decode(String.self, forKey: .exec) {
                    lines = [text]
                } else {
                    lines = []
                }
            }
        }

        var hasCode: Bool {
            script?.lines.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        }
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

    /// Postman örneği. Alanlar toleranslı: `code` sayı ya da metin, `header`
    /// dizi ya da (eski dışa aktarımlarda) düz metin, `body` metin ya da yok.
    struct PMResponse: Decodable {
        let name: String?
        let code: Int?
        let status: String?
        let header: [PMHeader]?
        let body: String?

        private enum CodingKeys: String, CodingKey { case name, code, status, header, body }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            if let number = try? container.decodeIfPresent(Int.self, forKey: .code) {
                code = number
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .code) {
                code = Int(text.trimmingCharacters(in: .whitespaces))
            } else {
                code = nil
            }
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            header = try? container.decodeIfPresent([PMHeader].self, forKey: .header)
            body = try? container.decodeIfPresent(String.self, forKey: .body)
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
    let event: [PMEvent]?

    var scriptCount: Int {
        (event ?? []).filter(\.hasCode).count + (item ?? []).reduce(0) { $0 + $1.scriptCount }
    }
}

extension CollectionPorting {
    // MARK: - Dışa aktarmada düz metin kimlik bilgisi

    /// Dışa aktarılan dosyada düz metin (vault referansı olmayan) kimlik
    /// bilgisi taşıyan request'ler ve yerleri. Başarı mesajı buna göre
    /// yazılır: önceden "secret yazılmadı" koşulsuz söyleniyordu, oysa düz
    /// metin bearer token dosyaya giriyordu (güvenlik incelemesi F6,
    /// 2026-10-20). Gövdedeki keyfi veri için tam sınıflandırma garantisi
    /// yok; tespit içe aktarma incelemesiyle aynı kurallar.
    public struct PlaintextCredential: Equatable, Sendable {
        public let requestName: String
        public let places: [String]
    }

    public static func plaintextCredentials(in collection: CollectionModel) -> [PlaintextCredential] {
        collection.requests.compactMap { request in
            let places = ImportReviewer.plaintextCredentials(in: request)
            return places.isEmpty ? nil : PlaintextCredential(requestName: request.name, places: places)
        }
    }
}
