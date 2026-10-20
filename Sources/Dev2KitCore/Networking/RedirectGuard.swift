import Foundation

/// Yönlendirme davranışının istek başına ayarları.
public struct RedirectPolicy: Codable, Hashable, Sendable {
    /// Yönlendirmeler izlensin mi (kapalıyken 3xx yanıtı olduğu gibi gösterilir).
    public var follow: Bool
    /// Zincir üst sınırı; döngüye giren sunucular için.
    public var maxRedirects: Int
    /// https → http düşüşüne izin verilsin mi. Varsayılan HAYIR.
    public var allowInsecureDowngrade: Bool

    public static let `default` = RedirectPolicy(follow: true, maxRedirects: 10, allowInsecureDowngrade: false)

    public init(follow: Bool = true, maxRedirects: Int = 10, allowInsecureDowngrade: Bool = false) {
        self.follow = follow
        self.maxRedirects = max(0, min(maxRedirects, 20))
        self.allowInsecureDowngrade = allowInsecureDowngrade
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            follow: try container.decodeIfPresent(Bool.self, forKey: .follow) ?? true,
            maxRedirects: try container.decodeIfPresent(Int.self, forKey: .maxRedirects) ?? 10,
            allowInsecureDowngrade: try container.decodeIfPresent(Bool.self, forKey: .allowInsecureDowngrade) ?? false
        )
    }
}

/// Zincirdeki tek bir yönlendirme adımı — kullanıcıya denetim izi olarak gösterilir.
public struct RedirectStep: Sendable, Hashable {
    public let statusCode: Int
    public let from: URL
    public let to: URL
    /// Kaynak değiştiği için kaldırılan hassas başlıklar.
    public let strippedHeaders: [String]

    public init(statusCode: Int, from: URL, to: URL, strippedHeaders: [String]) {
        self.statusCode = statusCode
        self.from = from
        self.to = to
        self.strippedHeaders = strippedHeaders
    }
}

/// Yönlendirme kararını veren saf mantık.
///
/// Neden gerekli: Foundation yönlendirmede `Authorization` başlığını kaynak
/// değişince kendisi düşürür — ama ÖZEL başlıkları aynen taşır. API anahtarları
/// çoğunlukla özel başlıkta gider (`X-Api-Key`, `X-Auth-Token`), dolayısıyla
/// yabancı bir host'a yönlendirme anahtarı oraya taşır. Burada isteğin kendi
/// kimlik taşıyan başlıkları da (API key başlığı ve `{{secret:...}}` referansı
/// içeren her başlık) kaynak değişiminde düşürülür.
public enum RedirectGuard {
    /// Her durumda kaynak değişiminde düşürülen standart başlıklar.
    public static let sensitiveHeaders = ["Authorization", "Cookie", "Proxy-Authorization", "WWW-Authenticate"]

    /// İsteğin kendi tanımından çıkarılan kimlik taşıyan başlık adları.
    /// Değeri `{{secret:...}}` ile gelen her başlık tanımı gereği gizli sayılır.
    public static func credentialHeaders(for model: RequestModel) -> [String] {
        var names = sensitiveHeaders
        if case .apiKey(let key, _, .header) = model.auth {
            let trimmed = key.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { names.append(trimmed) }
        }
        for entry in model.headers where entry.enabled
            && entry.value.localizedCaseInsensitiveContains("{{secret:")
            && !entry.key.isEmpty {
            names.append(entry.key)
        }
        // Aynı adın iki kez denenmesi zararsız ama listeyi sade tutalım.
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Standart hassas başlıklar + verilenler, büyük/küçük harf duyarsız tekil.
    public static func merged(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return (sensitiveHeaders + names).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public enum Decision: Equatable, Sendable {
        case follow(strippedHeaders: [String])
        case stop(reason: StopReason)

        public enum StopReason: String, Equatable, Sendable {
            case policyDisabled
            case tooManyRedirects
            case insecureDowngrade
            case hostNotAllowed

            public var explanation: String {
                switch self {
                case .policyDisabled: return L10n.t("redirect.disabled")
                case .tooManyRedirects: return L10n.t("redirect.tooMany")
                case .insecureDowngrade: return L10n.t("redirect.downgrade")
                case .hostNotAllowed: return L10n.t("redirect.hostNotAllowed")
                }
            }
        }
    }

    /// İki URL farklı kaynakta mı (şema, host veya port farklı)?
    /// Alt alan adları da farklı kaynak sayılır: api.firma.com → auth.firma.com
    /// geçişinde token taşımak, o alt alanı ele geçirenin token'ı almasına yol açar.
    public static func isCrossOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        }
        return lhs.scheme?.lowercased() != rhs.scheme?.lowercased()
            || lhs.host?.lowercased() != rhs.host?.lowercased()
            || port(lhs) != port(rhs)
    }

    public static func evaluate(
        from source: URL,
        to destination: URL,
        policy: RedirectPolicy,
        redirectCount: Int,
        credentialHeaders: [String] = sensitiveHeaders,
        hostPolicy: HostPolicyState = .notConfigured
    ) -> Decision {
        guard policy.follow else { return .stop(reason: .policyDisabled) }
        guard hostPolicy.violation(for: destination) == nil else { return .stop(reason: .hostNotAllowed) }
        guard redirectCount < policy.maxRedirects else { return .stop(reason: .tooManyRedirects) }

        let sourceSecure = source.scheme?.lowercased() == "https"
        let destinationSecure = destination.scheme?.lowercased() == "https"
        if sourceSecure, !destinationSecure, !policy.allowInsecureDowngrade {
            return .stop(reason: .insecureDowngrade)
        }

        return .follow(strippedHeaders: isCrossOrigin(source, destination) ? credentialHeaders : [])
    }
}
