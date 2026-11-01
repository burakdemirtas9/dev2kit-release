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

    /// Tam ad listesi + sınıflandırıcının ad kuralı (`HeaderClassifier`):
    /// yalnızca tam ad bakılınca `X-Vault-Token`, `X-Password`,
    /// `Ocp-Apim-Subscription-Key` geçmişe ve örneklere düz yazılıyordu
    /// (yeniden tarama, 2026-11-01). Ad yeter; maskeleme ihtiyatlıdır.
    public static func isCredentialHeader(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        return headers.contains(lower) || HeaderClassifier.hasCredentialKeyword(lower)
    }

    /// Alan adının herhangi bir yerinde geçmesi yeten sözcükler (`newPassword`,
    /// `accessKey`, `secretKey`, `sessionToken`, `jwt`).
    static let fieldKeywords = ["password", "passwd", "secret", "token", "apikey", "accesskey", "privatekey",
                                "credential", "jwt"]

    public static func isCredentialField(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespaces).lowercased()
        if fields.contains(normalized) { return true }
        // camelCase / kebab-case varyantları: accessToken, api-key…
        let flattened = normalized.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        if fieldKeywords.contains(where: flattened.contains) { return true }
        return fields.contains { $0.replacingOccurrences(of: "_", with: "") == flattened }
    }
}
