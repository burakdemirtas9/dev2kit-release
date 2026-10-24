import Foundation

/// Bir isteğin altında saklanan response örneği: belli bir andaki yanıtın
/// donmuş hali (status, header'lar, body, content type) ve onu üreten
/// request (Postman'deki `originalRequest`). İkisi de düzenlenebilir.
///
/// İsteğin içinde, koleksiyon dosyasında durur (`RequestModel.examples`):
/// istek silinince örnekleri de gider, istekle birlikte dışa aktarılır.
/// Kurallar (sınır, anlık görüntü, maskeleme) `ResponseExamples`'ta.
///
/// Kimlik bilgisi taşıyan header değerleri ve body'deki kimlik alanları
/// kaydedilirken maskelenir (`ResponseExamples.capture`): workspace dosyası
/// düz metin, secret'lar oraya yazılmaz.
public struct ResponseExample: Codable, Identifiable, Hashable, Sendable {
    /// Response header'ı. Kimlik düzenleme tablosunda satır kimliği olsun diye
    /// (yazarken satır yeniden kurulup odak kaybolmasın); `enabled` Postman'in
    /// `disabled` alanının karşılığı. Eski kayıtlarda ikisi de yok.
    public struct Header: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var value: String
        public var enabled: Bool

        public init(id: UUID = UUID(), name: String, value: String, enabled: Bool = true) {
            self.id = id
            self.name = name
            self.value = value
            self.enabled = enabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                name: try container.decode(String.self, forKey: .name),
                value: try container.decodeIfPresent(String.self, forKey: .value) ?? "",
                enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            )
        }
    }

    /// Body'nin dosyadaki biçimi. Metin okunur kalsın (git diff'i), metin
    /// olmayan (görsel, PDF) body base64.
    public enum BodyEncoding: String, Codable, Sendable {
        case text
        case base64
    }

    public var id: UUID
    public var name: String
    public var savedAt: Date
    public var statusCode: Int
    public var headers: [Header]
    public var body: String
    public var bodyEncoding: BodyEncoding
    /// Yanıtın Content-Type'ı; yanıtta yoksa `nil`.
    public var contentType: String?
    /// Bu yanıtı üreten request (şablon hali: `{{değişken}}`ler çözülmemiş,
    /// düz metin kimlik bilgileri maskeli). Özellik gelmeden kaydedilen
    /// örneklerde `nil`: uydurulmaz, ekranda "request kaydı yok".
    public var request: ExampleRequest?

    public init(
        id: UUID = UUID(),
        name: String,
        savedAt: Date = Date(),
        statusCode: Int,
        headers: [Header] = [],
        body: String = "",
        bodyEncoding: BodyEncoding = .text,
        contentType: String? = nil,
        request: ExampleRequest? = nil
    ) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyEncoding = bodyEncoding
        self.contentType = contentType
        self.request = request
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            savedAt: try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date(timeIntervalSince1970: 0),
            // Kod yoksa da örnek okunur (status doğrulanmaz).
            statusCode: (try? container.decodeIfPresent(Int.self, forKey: .statusCode)) ?? ResponseExamples.unknownStatus,
            headers: try container.decodeIfPresent([Header].self, forKey: .headers) ?? [],
            body: try container.decodeIfPresent(String.self, forKey: .body) ?? "",
            bodyEncoding: try container.decodeIfPresent(BodyEncoding.self, forKey: .bodyEncoding) ?? .text,
            contentType: try container.decodeIfPresent(String.self, forKey: .contentType),
            request: try container.decodeIfPresent(ExampleRequest.self, forKey: .request)
        )
    }

    /// Etkin header'lardan Content-Type (düzenlemeden sonra eşitlemek için).
    public var headerContentType: String? {
        headers.first { $0.enabled && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == "content-type" }?.value
    }

    /// Body'nin ham byte'ları (gösterim, önizleme, dosyaya kaydetme için).
    public var bodyData: Data {
        switch bodyEncoding {
        case .text: return Data(body.utf8)
        case .base64: return Data(base64Encoded: body) ?? Data()
        }
    }

    /// Kayıtlı yanıtı gösterim katmanının tanıdığı biçime çevirir. Süre,
    /// ağ künyesi ve yönlendirme saklanmaz; örnek bir ölçüm değil.
    public var responseData: ResponseData {
        ResponseData(
            statusCode: statusCode,
            headers: headers.filter(\.enabled).map { (name: $0.name, value: $0.value) },
            body: bodyData,
            duration: 0,
            finalURL: nil
        )
    }
}

/// Örneğin request tarafı: Postman `originalRequest`'inin karşılığı.
/// Tele çıkan alanlar (auth ayrı değil: kimlik bilgisi header'da ya da
/// `{{secret:…}}` referansında durur). Ad, ayarlar ve Token Factory alanı yok.
public struct ExampleRequest: Codable, Hashable, Sendable {
    public var method: HTTPMethod
    public var url: String
    public var headers: [KeyValueEntry]
    public var queryParams: [KeyValueEntry]
    public var body: RequestBody

    public init(
        method: HTTPMethod = .get,
        url: String = "",
        headers: [KeyValueEntry] = [],
        queryParams: [KeyValueEntry] = [],
        body: RequestBody = .none
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.queryParams = queryParams
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            method: try container.decodeIfPresent(HTTPMethod.self, forKey: .method) ?? .get,
            url: try container.decodeIfPresent(String.self, forKey: .url) ?? "",
            headers: try container.decodeIfPresent([KeyValueEntry].self, forKey: .headers) ?? [],
            queryParams: try container.decodeIfPresent([KeyValueEntry].self, forKey: .queryParams) ?? [],
            body: try container.decodeIfPresent(RequestBody.self, forKey: .body) ?? .none
        )
    }

    /// İsteğin tele çıkan kısmı, kimlik bilgileri maskeli (`HistoryRedactor`:
    /// geçmişle aynı kural; `{{secret:…}}` referansı olduğu gibi kalır).
    /// Auth yapılandırması header'a dönüştürülmez: değeri gönderim anında
    /// çözülüyor, örnekte yalnızca türü bilinir.
    public init(capturing request: RequestModel) {
        let masked = HistoryRedactor.redact(request)
        self.init(method: masked.method, url: masked.url, headers: masked.headers,
                  queryParams: masked.queryParams, body: masked.body)
    }

    /// Düzenleme ekranındaki editörler `RequestModel` bağlıyor; aradaki çeviri.
    public var asRequestModel: RequestModel {
        RequestModel(name: "", method: method, url: url, headers: headers, queryParams: queryParams, body: body)
    }

    public mutating func update(from model: RequestModel) {
        method = model.method
        url = model.url
        headers = model.headers
        queryParams = model.queryParams
        body = model.body
    }
}

public extension RequestModel {
    /// Örnekleri olmayan kopya. Son gönderilen hal (`sentBaselines`), geçmiş
    /// kaydı ve Token Factory kopyası örnek taşımaz: aynı body'ler başka
    /// dosyalarda çoğalmasın, geçmiş dosyasına yanıt sızmasın.
    var withoutExamples: RequestModel {
        var copy = self
        copy.examples = []
        return copy
    }

    /// Örneklere yeni kimlik verir. Kopyalanan ya da içe aktarılan istekte
    /// örnek kimliği başka bir örnekle çakışmasın (kenar çubuğu seçimi
    /// kimlikle çalışıyor).
    func regeneratingExampleIDs() -> RequestModel {
        var copy = self
        copy.examples = examples.map { example in
            var fresh = example
            fresh.id = UUID()
            return fresh
        }
        return copy
    }
}

/// Çözme sırasında okunamayıp atlanan örnekler. İçe aktarma, kullanıcıya
/// gerçek nedeni söylemek için `JSONDecoder.userInfo`'ya koyar; workspace
/// açılışında yoktur (atlanır, içerik loglanmaz).
public final class ExampleDecodeReport: @unchecked Sendable {
    public static let key = CodingUserInfoKey(rawValue: "dev2kit.exampleDecodeReport")!
    /// İstek adı ve okunamayan örnek sayısı, dosyadaki sırayla.
    public private(set) var unreadable: [(requestName: String, count: Int)] = []

    public init() {}

    func record(requestName: String, count: Int) {
        unreadable.append((requestName, count))
    }
}

/// Dizinin bozuk elemanlarını atlayarak çözer. Elle düzenlenmiş ya da yarım
/// kalmış tek bir örnek, isteğin ve koleksiyonun tamamını okunamaz yapmasın.
struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let droppedCount: Int

    /// Her JSON değerini kabul eder; bozuk elemanın üstünden geçmek için.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws { _ = try decoder.singleValueContainer() }
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                dropped += 1
                // İmleç ilerlesin; ilerleyemiyorsa sonsuz döngüye girmeden çık.
                if (try? container.decode(Skip.self)) == nil { break }
            }
        }
        self.elements = elements
        self.droppedCount = dropped
    }
}
