import Foundation

/// İstek bazlı kimlik doğrulama yapılandırması.
/// Değer alanları düz metin secret DEĞİL, şablon metnidir: `{{secret:github_token}}`
/// gibi referanslar gönderim anında çözülür. Kullanıcı düz metin de yazabilir ama
/// UI bunu caydırır ve secret'a taşımayı önerir.
public enum AuthConfig: Codable, Hashable, Sendable {
    case none
    case basic(username: String, password: String)
    case bearer(token: String)
    case apiKey(key: String, value: String, location: APIKeyLocation)
    /// Token vault'ta `config.tokenSecretName` altında tutulur; istek
    /// tanımında yalnızca yapılandırma durur, token hiç yazılmaz.
    case oauth2(OAuth2Config)

    public enum APIKeyLocation: String, Codable, CaseIterable, Sendable {
        case header
        case queryParam
    }

    public var displayName: String {
        switch self {
        case .none: return "Auth Yok"
        case .basic: return "Basic"
        case .bearer: return "Bearer Token"
        case .apiKey: return "API Key"
        case .oauth2: return "OAuth2"
        }
    }
}
