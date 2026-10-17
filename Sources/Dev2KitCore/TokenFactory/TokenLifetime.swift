import Foundation

/// Bir token'ın ne zaman yenilenmesi gerektiği.
///
/// Süre iki kaynaktan okunur, bu sırayla:
/// 1. Token bir JWT ise içindeki `exp`. Token'ın kendi beyanı, en kesin bilgi.
/// 2. Yanıt gövdesindeki `expires_in` (saniye, OAuth2 standardı).
///
/// İkisi de yoksa süre bilinmez: token, onu kullanan istek hata alıp kullanıcı
/// yenilemeyi seçene kadar kullanılır.
///
/// GÜVENLİK NOTU: JWT'nin imzası burada DOĞRULANMAZ ve doğrulanmamalıdır.
/// `exp` yalnızca "ne zaman yenilemeli" sorusu için okunur; token'a güvenip
/// güvenmemek onu kabul eden sunucunun işi. Bu değer hiçbir güvenlik kararında
/// kullanılmaz.
public enum TokenLifetime {
    /// Süre dolmadan bu kadar önce yenilenir. Saat kayması ve ağ gecikmesi
    /// için pay: tam sınırda giden istek sunucuda süresi dolmuş sayılabilir.
    public static let refreshLeeway: TimeInterval = 10

    public static func expiry(token: String, responseBody: Data, receivedAt: Date) -> Date? {
        if let exp = jwtExpiry(token) { return exp }
        return expiresIn(responseBody).map { receivedAt.addingTimeInterval($0) }
    }

    /// `expiresAt` verilmişse ve yenileme payı içine girildiyse true.
    /// Süre bilinmiyorsa (`nil`) yenileme gerekmez.
    public static func needsRefresh(expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(refreshLeeway) >= expiresAt
    }

    /// JWT'nin `exp` iddiası (saniye cinsinden Unix zamanı). JWT değilse `nil`.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        // JWS: başlık.yük.imza — JWE (5 parça) şifreli, yükü okunamaz.
        guard parts.count == 3, let payload = base64URLDecode(parts[1]),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = number(claims["exp"]), exp > 0
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func expiresIn(_ body: Data) -> TimeInterval? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let seconds = number(object["expires_in"]), seconds > 0
        else { return nil }
        return seconds
    }

    /// Sayı ya da sayısal metin ("300"). Bazı servisler `expires_in`'i metin
    /// olarak dönüyor.
    private static func number(_ value: Any?) -> Double? {
        // JSONSerialization true/false'u da NSNumber verir; onlar süre değil.
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func base64URLDecode(_ part: Substring) -> Data? {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
