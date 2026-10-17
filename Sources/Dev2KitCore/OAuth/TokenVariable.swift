import Foundation

/// ESKİ BİÇİM: environment içindeki OAuth2 client credentials "token değişkeni".
///
/// Artık oluşturulmuyor ve gönderimde kullanılmıyor; token işlemleri Token
/// Factory'de. Yalnızca eski workspace dosyalarını okuyup
/// `TokenFactoryMigration` ile Token Factory isteğine çevirmek için duruyor.
/// Silinirse eski dosyalardaki değişkenler sessizce kaybolur.
public struct TokenVariable: Codable, Hashable, Identifiable, Sendable {
    /// Client kimliğinin token uç noktasına nasıl sunulacağı.
    public enum ClientAuthentication: String, Codable, CaseIterable, Sendable {
        /// `Authorization: Basic …` (client_secret_basic; RFC'nin önerdiği yol).
        case basicHeader
        /// Gövdede `client_id` + `client_secret` (client_secret_post).
        case requestBody

        public var title: String {
            switch self {
            case .basicHeader: return "Basic başlığı"
            case .requestBody: return "Gövdede"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var tokenURL: String
    public var clientID: String
    public var clientSecret: String
    public var scope: String
    public var clientAuthentication: ClientAuthentication

    public init(
        id: UUID = UUID(),
        name: String = "accessToken",
        tokenURL: String = "",
        clientID: String = "",
        clientSecret: String = "",
        scope: String = "",
        clientAuthentication: ClientAuthentication = .basicHeader
    ) {
        self.id = id
        self.name = name
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.clientAuthentication = clientAuthentication
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "accessToken",
            tokenURL: try container.decodeIfPresent(String.self, forKey: .tokenURL) ?? "",
            clientID: try container.decodeIfPresent(String.self, forKey: .clientID) ?? "",
            clientSecret: try container.decodeIfPresent(String.self, forKey: .clientSecret) ?? "",
            scope: try container.decodeIfPresent(String.self, forKey: .scope) ?? "",
            clientAuthentication: try container.decodeIfPresent(ClientAuthentication.self, forKey: .clientAuthentication) ?? .basicHeader
        )
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
}
