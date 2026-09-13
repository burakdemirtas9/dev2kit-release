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

    public init(
        id: UUID = UUID(),
        name: String = "Yeni İstek",
        method: HTTPMethod = .get,
        url: String = "",
        headers: [KeyValueEntry] = [],
        queryParams: [KeyValueEntry] = [],
        body: RequestBody = .none,
        auth: AuthConfig = .none
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.url = url
        self.headers = headers
        self.queryParams = queryParams
        self.body = body
        self.auth = auth
    }
}
