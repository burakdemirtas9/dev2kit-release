import Foundation

/// Dışarıdan gelen (log, içe aktarma) bir başlığın ne olduğu.
public enum HeaderCategory: Int, CaseIterable, Sendable {
    /// Doğrudan alınabilir: content-type, accept, uygulama başlıkları.
    case normal
    /// Kimlik bilgisi ya da kişisel veri; varsayılan olarak alınmaz.
    case sensitive
    /// Proxy ve izleme başlıkları (x-forwarded-*, traceparent…); başka bir
    /// isteğin izine aittir, varsayılan olarak alınmaz.
    case infrastructure
    /// Asla alınmaz: hedefle ya da gövdeyle çakışır (host, content-length).
    case dropped

    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .sensitive: return "Hassas"
        case .infrastructure: return "Proxy / izleme"
        case .dropped: return "Her zaman atılır"
        }
    }
}

public struct ClassifiedHeader: Identifiable, Hashable, Sendable {
    public enum SensitiveKind: Sendable {
        /// Token, cookie, parola: düz metin yazılmaz, vault'a taşınır.
        case credential
        /// Kişisel veri (KVKK): alınırsa düz metin kalır, kullanıcı uyarılır.
        case personal
    }

    public let name: String
    public let value: String
    public let category: HeaderCategory
    public let sensitiveKind: SensitiveKind?
    /// Değer bir JWT ise `exp` alanı.
    public let expiresAt: Date?

    public var id: String { name.lowercased() }

    public func isExpired(now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

/// Başlıkları ada ve değere bakarak sınıflandırır. Şüphede hassas tarafa
/// düşer: yanlışlıkla hassas sayılan bir başlığı kullanıcı tek tıkla alır,
/// yanlışlıkla normal sayılan bir token ise sessizce düz metin yazılırdı.
public enum HeaderClassifier {
    public static func classify(name: String, value: String) -> ClassifiedHeader {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        let expiry = jwtExpiry(value)
        let (category, kind): (HeaderCategory, ClassifiedHeader.SensitiveKind?)
        // Sıra önemli: JWT ve bilinen kimlik bilgisi her istisnadan önce gelir;
        // x-forwarded-for ise proxy başlığı olsa da IP taşır.
        if droppedNames.contains(lower) {
            (category, kind) = (.dropped, nil)
        } else if credentialNames.contains(lower) || expiry != nil || looksLikeJWT(value) {
            (category, kind) = (.sensitive, .credential)
        } else if alwaysNormalNames.contains(lower) {
            (category, kind) = (.normal, nil)
        } else if ipHeaders.contains(lower) {
            (category, kind) = (.sensitive, .personal)
        } else if infrastructureNames.contains(lower) || infrastructurePrefixes.contains(where: lower.hasPrefix) {
            (category, kind) = (.infrastructure, nil)
        } else if credentialKeywords.contains(where: lower.contains), looksOpaque(value) {
            (category, kind) = (.sensitive, .credential)
        } else if personalKeywords.contains(where: lower.contains) {
            (category, kind) = (.sensitive, .personal)
        } else {
            (category, kind) = (.normal, nil)
        }
        return ClassifiedHeader(name: name, value: value, category: category, sensitiveKind: kind, expiresAt: expiry)
    }

    // MARK: - Kurallar

    /// URLSession bunları kendisi yönetir ya da bağlantıya özgüdür.
    static let droppedNames: Set<String> = [
        "host", "content-length", "connection", "keep-alive", "transfer-encoding",
        "te", "trailer", "upgrade", "proxy-connection",
    ]

    static let credentialNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key", "x-auth-token",
    ]

    static let credentialKeywords = ["token", "secret", "password", "passwd", "session", "apikey", "api-key", "auth"]

    /// Müşteri/kişi tanımlayan başlıklar.
    static let personalKeywords = [
        "customer", "identif", "identity", "birth", "name", "surname", "mpn", "msisdn", "phone", "gsm",
        "email", "tckn", "iban", "device-id", "vendor-id", "user-id", "user-client-id",
    ]

    /// Genel kurallara (kişisel veri anahtar kelimesi, izleme öneki) takılan ama
    /// kullanıcının normal saydığı başlıklar: uygulama bayrakları ve istek
    /// tekrarında gereken kimlikler. Değerleri token gibi görünürse yine vault'a
    /// gider: o kontrol bu listeden önce gelir.
    static let alwaysNormalNames: Set<String> = [
        "x-banking-customer-number", "x-customer-external-user-id", "x-customer-first-login",
        "x-customer-has-external-device", "x-customer-kvkk-flag", "x-getir-user-client-id", "x-device-vendor-id",
        "x-correlation-id", "x-b3-sessionid",
    ]

    /// İstemci IP'si kişisel veridir; proxy başlığı olsalar da hassas sayılır.
    static let ipHeaders: Set<String> = ["x-forwarded-for", "x-real-ip", "x-ip-address", "x-client-ip", "forwarded"]

    static let infrastructureNames: Set<String> = [
        "via", "traceparent", "tracestate", "b3", "x-request-id", "x-amzn-trace-id",
        "uber-trace-id", "x-cloud-trace-context", "x-client-port", "x-client-source-port",
    ]

    static let infrastructurePrefixes = ["x-forwarded-", "x-b3-", "x-instana-", "x-datadog-", "x-envoy-"]

    /// Ad tek başına yetmez: `x-token-type: Bearer` ya da `x-token-issued-at:
    /// <tarih>` kimlik bilgisi değildir. Adında anahtar kelime geçen başlığın
    /// değeri de opak olmalı: uzun, boşluksuz, tarih ya da sayı değil.
    static func looksOpaque(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 16, !trimmed.contains(" ") else { return false }
        if trimmed.allSatisfy(\.isNumber) { return false }
        if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return false }
        return true
    }

    static func looksLikeJWT(_ value: String) -> Bool {
        let trimmed = value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : value
        return trimmed.range(of: #"^eyJ[\w-]*\.[\w-]+\.[\w-]*$"#, options: .regularExpression) != nil
    }

    /// Yalnızca `exp` okunur; imza doğrulanmaz, token içeriği hiçbir yere yazılmaz.
    /// Çözümleme Token Factory ile ortak (`TokenLifetime.jwtExpiry`).
    static func jwtExpiry(_ value: String) -> Date? {
        let token = value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : value
        guard token.hasPrefix("eyJ") else { return nil }
        return TokenLifetime.jwtExpiry(token)
    }
}
