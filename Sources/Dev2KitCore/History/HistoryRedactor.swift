import Foundation

/// Geçmişe yazılmadan önce kimlik bilgilerini maskeler.
///
/// Kural: `{{secret:isim}}` gibi bir REFERANS zaten gizli değildir, olduğu gibi
/// kalır — ne gönderdiğini anlaman için gereken bilgi odur. Ama kullanıcı
/// doğrudan ham bir token yazdıysa, o değer maskelenir. Aksi halde vault'ta
/// şifrelediğimiz secret'ları geçmiş dosyasına düz metin yazmış olurduk.
public enum HistoryRedactor {
    public static let mask = "••••••"

    /// Değer bir şablon referansıysa gizli sayılmaz; ham değerse maskelenir.
    private static func maskIfLiteral(_ value: String) -> String {
        if value.isEmpty { return value }
        if value.contains("{{") && value.contains("}}") { return value }
        return mask
    }

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
        let pattern = #/"([A-Za-z0-9_\-]+)"\s*:\s*"((?:\\.|[^"\\])*)"/#
        var output = ""
        var lastIndex = text.startIndex
        for match in text.matches(of: pattern) {
            output += text[lastIndex..<match.range.lowerBound]
            let key = String(match.1)
            let value = String(match.2)
            if CredentialNames.isCredentialField(key) {
                output += "\"\(key)\": \"\(maskIfLiteral(value))\""
            } else {
                output += text[match.range]
            }
            lastIndex = match.range.upperBound
        }
        output += text[lastIndex...]
        return output
    }

    /// Yanıt önizlemesi: kimlik alanları maskelenir ve boyut sınırlanır.
    public static func redactResponse(_ text: String, limit: Int) -> String {
        let masked = redactStructuredText(text)
        guard masked.count > limit else { return masked }
        return String(masked.prefix(limit)) + "\n" + L10n.plural("history.charsTrimmed", count: masked.count - limit)
    }
}
