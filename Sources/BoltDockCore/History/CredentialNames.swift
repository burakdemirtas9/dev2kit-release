import Foundation

/// Kimlik bilgisi taşıdığı bilinen başlık, alan ve parametre adları.
///
/// Tek yerde tutulur çünkü hem yönlendirme korumasında hem geçmiş
/// maskelemesinde aynı liste kullanılır; ikisinin ayrışması bir tarafta
/// açık bırakır.
public enum CredentialNames {
    /// HTTP başlıkları.
    public static let headers: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
        "x-api-key", "api-key", "apikey", "x-auth-token", "x-access-token",
        "authentication", "x-csrf-token", "x-session-token",
    ]

    /// JSON alanları, form alanları ve query parametreleri.
    public static let fields: Set<String> = [
        "password", "passwd", "pwd", "pass",
        "token", "access_token", "refresh_token", "id_token", "auth_token",
        "secret", "client_secret", "api_key", "apikey", "apisecret",
        "key", "signature", "sig", "authorization",
        "session", "sessionid", "session_id", "jsessionid",
        "credential", "credentials", "otp", "pin",
    ]

    public static func isCredentialHeader(_ name: String) -> Bool {
        headers.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public static func isCredentialField(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespaces).lowercased()
        if fields.contains(normalized) { return true }
        // camelCase / kebab-case varyantları: accessToken, api-key…
        let flattened = normalized.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return fields.contains { $0.replacingOccurrences(of: "_", with: "") == flattened }
    }
}
