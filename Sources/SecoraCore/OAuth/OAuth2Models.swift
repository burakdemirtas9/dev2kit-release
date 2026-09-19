import Foundation

/// OAuth2 sağlayıcı yapılandırması.
///
/// `clientSecret` alanı var ama native uygulamalar "public client"tır ve gizli
/// tutamaz; bu yüzden PKCE zorunludur. Alan yalnızca bazı kurumsal IdP'lerin
/// ısrarla istediği durumlar için ve `{{secret:isim}}` referansı kabul eder.
public struct OAuth2Config: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var authorizationURL: String
    public var tokenURL: String
    public var clientID: String
    public var clientSecret: String
    public var scopes: String
    /// Auth0 gibi sağlayıcıların istediği ek parametreler (audience, prompt…).
    public var extraParameters: [KeyValueEntry]

    public init(
        id: UUID = UUID(),
        name: String = "OAuth2",
        authorizationURL: String = "",
        tokenURL: String = "",
        clientID: String = "",
        clientSecret: String = "",
        scopes: String = "",
        extraParameters: [KeyValueEntry] = []
    ) {
        self.id = id
        self.name = name
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.extraParameters = extraParameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "OAuth2",
            authorizationURL: try container.decodeIfPresent(String.self, forKey: .authorizationURL) ?? "",
            tokenURL: try container.decodeIfPresent(String.self, forKey: .tokenURL) ?? "",
            clientID: try container.decodeIfPresent(String.self, forKey: .clientID) ?? "",
            clientSecret: try container.decodeIfPresent(String.self, forKey: .clientSecret) ?? "",
            scopes: try container.decodeIfPresent(String.self, forKey: .scopes) ?? "",
            extraParameters: try container.decodeIfPresent([KeyValueEntry].self, forKey: .extraParameters) ?? []
        )
    }

    /// Vault'ta token'ın saklandığı ad. Token asla workspace dosyasına yazılmaz.
    public var tokenSecretName: String { "oauth2.\(id.uuidString)" }
}

/// Sağlayıcıdan alınan token kümesi. Vault'ta şifreli saklanır.
public struct OAuth2Token: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String
    public var expiresAt: Date?
    public var scope: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        tokenType: String = "Bearer",
        expiresAt: Date? = nil,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// Saat kaymasına ve ağ gecikmesine karşı 30 saniye pay bırakılır:
    /// tam sınırda gönderilen istek sunucuda süresi dolmuş sayılabilir.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    public var authorizationHeaderValue: String {
        let scheme = tokenType.isEmpty ? "Bearer" : tokenType
        return "\(scheme) \(accessToken)"
    }
}

/// Sağlayıcının token uç noktasından dönen ham yanıt.
struct OAuth2TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let token_type: String?
    let expires_in: Double?
    let scope: String?
}

/// Sağlayıcının RFC 6749 §5.2 biçimindeki hata yanıtı.
struct OAuth2ErrorResponse: Decodable {
    let error: String
    let error_description: String?
}
