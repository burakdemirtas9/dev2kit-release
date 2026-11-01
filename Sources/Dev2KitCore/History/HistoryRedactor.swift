import Foundation

/// Geçmişe yazılmadan önce kimlik bilgilerini maskeler.
///
/// Kural: `{{secret:isim}}` gibi bir REFERANS zaten gizli değildir, olduğu gibi
/// kalır — ne gönderdiğini anlaman için gereken bilgi odur. Ama kullanıcı
/// doğrudan ham bir token yazdıysa, o değer maskelenir. Aksi halde vault'ta
/// şifrelediğimiz secret'ları geçmiş dosyasına düz metin yazmış olurduk.
public enum HistoryRedactor {
    public static let mask = "••••••"

    /// Değer yalnızca şablon referansıysa (önünde kimlik şeması olabilir:
    /// `Bearer {{token}}`) gizli sayılmaz; içinde düz metin varsa maskelenir.
    /// Eskiden `{{` geçmesi yetiyordu: `p{{x}}gercekParola` açık kalıyordu.
    private static func maskIfLiteral(_ value: String) -> String {
        if value.isEmpty { return value }
        var rest = value.trimmingCharacters(in: .whitespaces)
        if let scheme = HeaderClassifier.authSchemes.first(where: { rest.lowercased().hasPrefix($0) }) {
            rest = String(rest.dropFirst(scheme.count))
        }
        let literal = rest.replacingOccurrences(of: #"\{\{[^{}]*\}\}"#, with: "", options: .regularExpression)
        if rest != literal, literal.trimmingCharacters(in: .whitespaces).isEmpty { return value }
        return mask
    }

    /// Adı ne olursa olsun değer bir token biçimindeyse (JWT, bilinen sağlayıcı
    /// önekleri) maskelenir: `"data": "eyJ…"`. Ucuz önek denetimi; her
    /// değerde regex derlenmez (yanıtlar büyük olabilir).
    static func looksLikeToken(_ value: String) -> Bool {
        let trimmed = value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : value
        guard trimmed.count >= 20, !trimmed.contains(" ") else { return false }
        if trimmed.hasPrefix("eyJ"), trimmed.filter({ $0 == "." }).count == 2 { return true }
        return tokenPrefixes.contains(where: trimmed.hasPrefix)
    }

    static let tokenPrefixes = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "xoxa-", "xoxb-", "xoxp-",
                                "xoxr-", "xoxs-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "AIza", "glpat-",
                                "sk-", "AKIA", "ASIA"]

    public static func redact(_ model: RequestModel) -> RequestModel {
        var copy = model
        copy.url = maskURL(model.url)
        copy.headers = model.headers.map { entry in
            var masked = entry
            if CredentialNames.isCredentialHeader(entry.key) {
                masked.value = maskIfLiteral(entry.value)
            }
            return masked
        }
        copy.queryParams = model.queryParams.map { entry in
            var masked = entry
            if CredentialNames.isCredentialField(entry.key) {
                masked.value = maskIfLiteral(entry.value)
            }
            return masked
        }
        copy.auth = redactAuth(model.auth)
        copy.body = redactBody(model.body)
        return copy
    }

    private static func redactAuth(_ auth: AuthConfig) -> AuthConfig {
        switch auth {
        case .none:
            return .none
        case .basic(let username, let password):
            return .basic(username: username, password: maskIfLiteral(password))
        case .bearer(let token):
            return .bearer(token: maskIfLiteral(token))
        case .apiKey(let key, let value, let location):
            return .apiKey(key: key, value: maskIfLiteral(value), location: location)
        case .oauth2(var config):
            // Token vault'ta; yapılandırmada yalnızca client secret gizli olabilir.
            config.clientSecret = maskIfLiteral(config.clientSecret)
            return .oauth2(config)
        }
    }

    private static func redactBody(_ body: RequestBody) -> RequestBody {
        switch body {
        case .none:
            return .none
        case .raw(let content, let contentType):
            return .raw(content: redactStructuredText(content), contentType: contentType)
        case .formURLEncoded(let fields):
            return .formURLEncoded(fields: redactFields(fields))
        case .multipartForm(let fields):
            return .multipartForm(fields: redactFields(fields))
        }
    }

    private static func redactFields(_ fields: [KeyValueEntry]) -> [KeyValueEntry] {
        fields.map { entry in
            var masked = entry
            if CredentialNames.isCredentialField(entry.key) {
                masked.value = maskIfLiteral(entry.value)
            }
            return masked
        }
    }

    /// Query parametrelerinden kimlik taşıyanları maskeler; adresin geri kalanı
    /// okunur kalır (hangi endpoint'e gittiğini görmek geçmişin asıl faydası).
    public static func maskURL(_ url: String) -> String {
        guard let separator = url.firstIndex(of: "?") else { return url }
        let base = String(url[url.startIndex..<separator])
        let query = String(url[url.index(after: separator)...])
        let maskedQuery = query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            guard let equals = pair.firstIndex(of: "=") else { return String(pair) }
            let key = String(pair[pair.startIndex..<equals])
            let value = String(pair[pair.index(after: equals)...])
            guard CredentialNames.isCredentialField(key) else { return String(pair) }
            return "\(key)=\(maskIfLiteral(value))"
        }.joined(separator: "&")
        return "\(base)?\(maskedQuery)"
    }

    /// JSON benzeri metinde kimlik taşıyan alanların DEĞERLERİNİ maskeler.
    /// Tam bir parser değil: `"alan": "değer"` kalıbını hedefler, bozuk JSON'da
    /// da çalışır ve yapıyı bozmaz.
    public static func redactStructuredText(_ text: String) -> String {
        guard text.contains(":") else { return text }
        // Değer metin ya da sayı: kimlik alanındaki sayı da (`"pin": 1234`) maskelenir.
        let pattern = #/"([A-Za-z0-9_\-]+)"\s*:\s*(?:"((?:\\.|[^"\\])*)"|(-?\d+(?:\.\d+)?))/#
        var output = ""
        var lastIndex = text.startIndex
        for match in text.matches(of: pattern) {
            output += text[lastIndex..<match.range.lowerBound]
            let key = String(match.1)
            let isCredential = CredentialNames.isCredentialField(key)
            if let quoted = match.2 {
                let value = String(quoted)
                if isCredential {
                    output += "\"\(key)\": \"\(maskIfLiteral(value))\""
                } else if looksLikeToken(value) {
                    output += "\"\(key)\": \"\(mask)\""
                } else {
                    output += text[match.range]
                }
            } else if isCredential {
                output += "\"\(key)\": \"\(mask)\""
            } else {
                output += text[match.range]
            }
            lastIndex = match.range.upperBound
        }
        output += text[lastIndex...]
        return output
    }

    /// Sınırın ötesinde maskelenen pay. Maskeleme önce metnin TAMAMINDA
    /// çalışıp sonra kırpılıyordu: geçmiş MainActor'da yazıldığı için 5 MB
    /// yanıt her gönderimde 2,2 sn, 20 MB 8,8 sn donduruyordu (yeniden
    /// inceleme, 2026-11-01, ölçüldü). Artık sınır + pay kadarı maskelenir;
    /// pay, sınırı kesen bir değerin tamamının görülmesi için. Bu paydan
    /// uzun bir kimlik değeri sınırı keserse eşleşmeyebilir (gerçekçi değil).
    static let redactionMargin = 65_536

    /// Yanıt önizlemesi: kimlik alanları maskelenir ve boyut sınırlanır.
    public static func redactResponse(_ text: String, limit: Int) -> String {
        let window = text.prefix(limit + redactionMargin)
        let rest = text[window.endIndex...]
        let masked = redactStructuredText(String(window))
        guard masked.count > limit || !rest.isEmpty else { return masked }
        let trimmed = masked.count - limit + rest.count
        return String(masked.prefix(limit)) + "\n" + L10n.plural("history.charsTrimmed", count: trimmed)
    }

    /// Geçmişe yazılan istek kopyası: gövde önce sınır + pay kadar kırpılır,
    /// maskelenir, sonra sınıra kırpılır (bkz. `redactionMargin`). Eskiden
    /// tamamı maskelenip sonra kırpılıyordu.
    public static func snapshot(_ model: RequestModel, maxBodyBytes: Int) -> RequestModel {
        let window = HistoryTrimmer.trim(model, maxBodyBytes: maxBodyBytes + redactionMargin)
        return HistoryTrimmer.trim(redact(window), maxBodyBytes: maxBodyBytes)
    }
}
