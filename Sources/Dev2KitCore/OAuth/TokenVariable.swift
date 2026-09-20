import Foundation

/// Değeri OAuth2 client credentials akışıyla alınan environment değişkeni.
///
/// İsteklerde sıradan bir değişken gibi `{{isim}}` olarak kullanılır. Token
/// bellekte tutulur ve yalnızca süresi dolunca (ya da hiç yokken) yeniden
/// alınır; diske, vault'a bile yazılmaz. Adres ve client bilgileri şablon
/// olabilir: `{{authUrl}}/token`, `{{secret:client_secret}}`.
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

    /// Gönderim sırasında token'ın göründüğü secret adı. Değişken bu ada
    /// yönlendirilir ki güvenlik kontrolleri token'ı secret olarak tanısın
    /// (şifresiz http uyarısı, yeni host onayı). Vault'ta böyle bir kayıt yoktur;
    /// değer bellekteki token'dan gelir (`OverlaySecretStore`).
    public var secretName: String { "oauth2-token/\(name)" }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
}

public enum TokenVariables {
    /// İsteğin doğrudan ya da başka değişkenler üzerinden kullandığı token değişkenleri.
    public static func referenced(by model: RequestModel, environment: EnvironmentModel?) -> [TokenVariable] {
        guard let environment, !environment.tokenVariables.isEmpty else { return [] }
        let names = SecretReferences.variableNames(in: model, environment: environment)
        return environment.tokenVariables.filter { names.contains($0.trimmedName) }
    }

    /// Gönderim için environment: token değişkenleri `{{secret:<secretName>}}`
    /// değerini alır. Aynı adlı düz değişken varsa token değişkeni kazanır.
    public static func environmentForSend(_ environment: EnvironmentModel) -> EnvironmentModel {
        guard !environment.tokenVariables.isEmpty else { return environment }
        var copy = environment
        let tokenNames = Set(environment.tokenVariables.map(\.trimmedName))
        copy.variables.removeAll { tokenNames.contains($0.key) }
        copy.variables += environment.tokenVariables
            .filter { !$0.trimmedName.isEmpty }
            .map { KeyValueEntry(key: $0.trimmedName, value: "{{secret:\($0.secretName)}}") }
        return copy
    }
}

/// Asıl secret deposunun önüne bellekteki değerleri koyar. Yazma ve silme
/// asıl depoya gider; bellekteki değerler hiçbir zaman diske yazılmaz.
public final class OverlaySecretStore: SecretStore, @unchecked Sendable {
    private let base: SecretStore
    private let overrides: [String: String]

    public init(base: SecretStore, overrides: [String: String]) {
        self.base = base
        self.overrides = overrides
    }

    public func secret(forName name: String) throws -> String? {
        if let value = overrides[name] { return value }
        return try base.secret(forName: name)
    }

    public func setSecret(_ value: String, forName name: String) throws {
        try base.setSecret(value, forName: name)
    }

    public func deleteSecret(forName name: String) throws {
        try base.deleteSecret(forName: name)
    }

    public func listSecretNames() throws -> [String] {
        try base.listSecretNames()
    }
}
