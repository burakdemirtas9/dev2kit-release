import Foundation

public enum HTTPMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    public var id: String { rawValue }

    /// Bu metot gövde taşıyabilir mi.
    ///
    /// HTTP'nin kendisi GET gövdesini yasaklamaz (Elasticsearch `_search` gibi
    /// API'ler kullanır) ama URLSession göndermez. Ölçüldü — macOS 26 /
    /// Darwin 27, CFNetwork 3896, yerel dinleyiciye karşı: GET + gövde
    /// `-1103` ("kaynak en fazla büyüklüğü aşıyor") ile HİÇ ağa çıkmıyor.
    /// `httpBody`, `httpBodyStream` ve `upload(for:from:)` yollarının üçü de
    /// aynı hatayı veriyor. HEAD, OPTIONS, DELETE, POST, PUT ve PATCH gövdeyi
    /// telde taşıyor (aynı ölçümde doğrulandı).
    public var allowsBody: Bool { self != .get }
}

/// Header/query satırı. `enabled` ile satır silinmeden devre dışı bırakılabilir.
public struct KeyValueEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var enabled: Bool

    public init(id: UUID = UUID(), key: String = "", value: String = "", enabled: Bool = true) {
        self.id = id
        self.key = key
        self.value = value
        self.enabled = enabled
    }
}

public enum RequestBody: Codable, Hashable, Sendable {
    case none
    case raw(content: String, contentType: String)
    /// application/x-www-form-urlencoded — key=value&... olarak gönderilir.
    case formURLEncoded(fields: [KeyValueEntry])
    /// multipart/form-data — MVP'de yalnızca metin alanları (dosya desteği sonra).
    case multipartForm(fields: [KeyValueEntry])
}

/// İstek başına ağ davranışı. Eksik alanlar güvenli varsayılana düşer;
/// eski workspace dosyaları (bu alan yokken yazılmış) sorunsuz okunur.
public struct RequestOptions: Codable, Hashable, Sendable {
    /// Saniye. Sunucu yanıt vermezse istek bu süre sonunda düşer.
    public var timeout: TimeInterval
    public var redirect: RedirectPolicy
    /// Oturum çerezleri bu isteğe eklensin / yanıttakiler kavanoza alınsın mı.
    public var sendCookies: Bool

    public static let timeoutRange: ClosedRange<TimeInterval> = 1...300
    public static let `default` = RequestOptions()

    public init(
        timeout: TimeInterval = 30,
        redirect: RedirectPolicy = .default,
        sendCookies: Bool = true
    ) {
        self.timeout = min(max(timeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
        self.redirect = redirect
        self.sendCookies = sendCookies
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timeout: try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 30,
            redirect: try container.decodeIfPresent(RedirectPolicy.self, forKey: .redirect) ?? .default,
            sendCookies: try container.decodeIfPresent(Bool.self, forKey: .sendCookies) ?? true
        )
    }
}

/// Tek bir HTTP isteğinin diske yazılan tanımı.
/// DİKKAT: Bu model asla çözülmüş secret değeri içermez; secret'lar
/// `{{secret:isim}}` referansı olarak durur ve gönderim anında Keychain'den çözülür.
public struct RequestModel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var method: HTTPMethod
    public var url: String
    public var headers: [KeyValueEntry]
    public var queryParams: [KeyValueEntry]
    public var body: RequestBody
    public var auth: AuthConfig
    /// Eski dosyalarda yok; okunurken varsayılana düşer.
    public var options: RequestOptions

    public init(
        id: UUID = UUID(),
        name: String = "Yeni İstek",
        method: HTTPMethod = .get,
        url: String = "",
        headers: [KeyValueEntry] = [],
        queryParams: [KeyValueEntry] = [],
        body: RequestBody = .none,
        auth: AuthConfig = .none,
        options: RequestOptions = .default
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.url = url
        self.headers = headers
        self.queryParams = queryParams
        self.body = body
        self.auth = auth
        self.options = options
    }

    /// İki isteğin TELE ÇIKAN kısmı aynı mı.
    ///
    /// `id` ve `name` dışarıda bırakılır: isteği yeniden adlandırmak
    /// gönderilecek şeyi değiştirmez, dolayısıyla "değişti" işareti
    /// çıkarmamalı. Karşılaştırma "şu an göndereceğim şey, en son test
    /// ettiğimle aynı mı" sorusunu yanıtlar.
    /// İşlevsel alanları verilen referans hale döndürür; `id` ve `name` korunur.
    ///
    /// `isFunctionallyEqual` ile AYNI alan kümesini kullanır: biri değişirse
    /// diğeri de değişmeli, yoksa "farklı" işareti duran ama geri dönüşü
    /// eksik bir istek ortaya çıkar.
    public func revertingFunctionalFields(to baseline: RequestModel) -> RequestModel {
        var reverted = self
        reverted.method = baseline.method
        reverted.url = baseline.url
        reverted.headers = baseline.headers
        reverted.queryParams = baseline.queryParams
        reverted.body = baseline.body
        reverted.auth = baseline.auth
        reverted.options = baseline.options
        return reverted
    }

    public func isFunctionallyEqual(to other: RequestModel) -> Bool {
        method == other.method
            && url == other.url
            && headers == other.headers
            && queryParams == other.queryParams
            && body == other.body
            && auth == other.auth
            && options == other.options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            method: try container.decode(HTTPMethod.self, forKey: .method),
            url: try container.decode(String.self, forKey: .url),
            headers: try container.decodeIfPresent([KeyValueEntry].self, forKey: .headers) ?? [],
            queryParams: try container.decodeIfPresent([KeyValueEntry].self, forKey: .queryParams) ?? [],
            body: try container.decodeIfPresent(RequestBody.self, forKey: .body) ?? .none,
            auth: try container.decodeIfPresent(AuthConfig.self, forKey: .auth) ?? .none,
            options: try container.decodeIfPresent(RequestOptions.self, forKey: .options) ?? .default
        )
    }
}
