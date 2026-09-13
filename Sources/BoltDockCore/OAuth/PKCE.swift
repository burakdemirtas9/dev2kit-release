import CryptoKit
import Foundation

/// RFC 7636 — Proof Key for Code Exchange.
///
/// Yetkilendirme kodunu çalan bir saldırganın onu token'a çeviremmesini sağlar:
/// kod, yalnızca doğrulayıcıyı (verifier) bilenin kullanabileceği bir meydan
/// okumaya (challenge) bağlanır.
///
/// Yalnızca `S256` desteklenir. RFC'nin izin verdiği `plain` yöntemi
/// bilinçli olarak YOK: challenge = verifier demek olduğu için PKCE'yi
/// anlamsız kılar ve kodu yakalayan saldırgan onu doğrudan kullanabilir.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }

    /// Kriptografik rastgele doğrulayıcı üretir (RFC 7636 §4.1: 43-128 karakter).
    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        // Tahmin edilebilir bir verifier PKCE'yi işlevsiz bırakır; sistem
        // CSPRNG'i kullanılır, asla `Int.random` gibi bir kaynak değil.
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Güvenli rastgelelik alınamadı")
        return PKCE(verifier: Data(bytes).base64URLEncodedString())
    }

    /// Yetkilendirme isteğine eşlik eden, tahmin edilemez oturum belirteci.
    /// Callback'te doğrulanır; doğrulanmazsa kod enjeksiyonu / CSRF mümkün olur.
    public static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Güvenli rastgelelik alınamadı")
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    /// base64url (RFC 4648 §5): `+` → `-`, `/` → `_`, dolgu yok.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
