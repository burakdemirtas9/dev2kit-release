import Foundation

/// Bir Token Factory isteğinin yanıtından hangi alanın hangi değişkene
/// yazılacağı.
///
/// Token değeri hiçbir zaman burada ya da diskte durmaz; yalnızca bellekte
/// tutulur (bkz. `TokenFactory.secretName(for:)`).
public struct TokenOutput: Codable, Hashable, Sendable {
    public static let defaultResponseField = "access_token"
    public static let defaultVariableName = "token"

    /// Yanıt gövdesindeki alanın yolu: `access_token`, `data.token`,
    /// `items[0].jwt`.
    public var responseField: String
    /// İsteklerde `{{isim}}` olarak kullanılacak değişken.
    public var variableName: String
    /// Yalnızca bu environment etkinken mi geçerli. `nil`: hepsinde.
    ///
    /// Aynı değişken her environment'ta farklı bir token servisinden gelebilir
    /// (Dev / Prod); adresi `{{authUrl}}` ile değiştirmek yetmediğinde.
    public var environmentID: UUID?

    public init(
        responseField: String = TokenOutput.defaultResponseField,
        variableName: String = TokenOutput.defaultVariableName,
        environmentID: UUID? = nil
    ) {
        self.responseField = responseField
        self.variableName = variableName
        self.environmentID = environmentID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            responseField: try container.decodeIfPresent(String.self, forKey: .responseField)
                ?? TokenOutput.defaultResponseField,
            variableName: try container.decodeIfPresent(String.self, forKey: .variableName)
                ?? TokenOutput.defaultVariableName,
            environmentID: try container.decodeIfPresent(UUID.self, forKey: .environmentID)
        )
    }

    public var trimmedVariableName: String { variableName.trimmingCharacters(in: .whitespaces) }
    public var trimmedResponseField: String { responseField.trimmingCharacters(in: .whitespaces) }

    /// Bu environment etkinken geçerli mi.
    public func applies(to environment: EnvironmentModel?) -> Bool {
        guard let environmentID else { return true }
        return environment?.id == environmentID
    }
}
