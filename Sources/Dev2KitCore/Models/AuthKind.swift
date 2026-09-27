import Foundation

/// Kimlik doğrulama türü — arayüzdeki seçicinin ortak dili.
///
/// `BodyKind` ile aynı desen: tür ve "o türün boş hali" kuralı Core'da,
/// görünen ad arayüzde. Böylece yeni bir auth türü eklendiğinde derleyici
/// eksik kalan yerleri gösterir.
public enum AuthKind: String, CaseIterable, Identifiable, Sendable {
    case none
    case basic
    case bearer
    case apiKey
    case oauth2

    public var id: String { rawValue }
}

public extension AuthConfig {
    var kind: AuthKind {
        switch self {
        case .none: return .none
        case .basic: return .basic
        case .bearer: return .bearer
        case .apiKey: return .apiKey
        case .oauth2: return .oauth2
        }
    }

    /// Türün boş hali. API key'in varsayılan başlık adı `X-Api-Key`:
    /// en yaygın kullanım, kullanıcı yazmak zorunda kalmasın.
    static func empty(_ kind: AuthKind) -> AuthConfig {
        switch kind {
        case .none: return .none
        case .basic: return .basic(username: "", password: "")
        case .bearer: return .bearer(token: "")
        case .apiKey: return .apiKey(key: "X-Api-Key", value: "", location: .header)
        case .oauth2: return .oauth2(OAuth2Config())
        }
    }
}
