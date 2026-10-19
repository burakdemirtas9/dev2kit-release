import Foundation

/// İsteği kopyalanabilir bir curl komutuna çevirir.
///
/// `includeSecrets=false` (varsayılan) iken `{{secret:isim}}` referansları
/// çözülmeden bırakılır; komut panoya güvenle kopyalanabilir. `true` iken
/// gerçek değerler Keychain'den çözülür — riske kullanıcı bilerek karar verir.
public enum CurlExporter {
    private static let engine = RequestEngine()

    /// Secret'ları çözmek yerine placeholder metnini geri veren store.
    private struct PlaceholderSecretStore: SecretStore {
        func setSecret(_ value: String, forName name: String) throws {}
        func secret(forName name: String) throws -> String? { "{{secret:\(name)}}" }
        func deleteSecret(forName name: String) throws {}
        func listSecretNames() throws -> [String] { [] }
    }

    public static func export(
        _ model: RequestModel,
        environment: EnvironmentModel?,
        secretStore: SecretStore,
        includeSecrets: Bool = false
    ) throws -> String {
        let store: SecretStore = includeSecrets ? secretStore : PlaceholderSecretStore()
        let resolver = VariableResolver(environment: environment, secretStore: store)
        let request = try engine.buildURLRequest(model, resolver: resolver)

        var parts: [String] = []
        parts.append("curl -X \(model.method.rawValue) \(shellQuote(request.url?.absoluteString ?? ""))")

        var headers = request.allHTTPHeaderFields ?? [:]
        headers = headers.filter { $0.key.caseInsensitiveCompare("Content-Length") != .orderedSame }
        // dev2kit'in User-Agent'ı dışa aktarılmaz: komut curl ile/başka yerde
        // çalışır, o trafiği "dev2kit" diye etiketlemek logda ayırt etme
        // amacına ters olurdu (Dev2KitIdentity).
        headers = headers.filter { !Dev2KitIdentity.isUserAgent($0.key) }

        // Basic auth curl'de -u ile daha okunur; base64'lü header yerine onu kullan.
        if case .basic(let username, let password) = model.auth {
            headers = headers.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
            let credentials = "\(try resolver.resolve(username)):\(try resolver.resolve(password))"
            parts.append("-u \(shellQuote(credentials))")
        }
        // Multipart'ta curl kendi boundary'sini üretir; bizim boundary'li header yanıltır.
        if case .multipartForm = model.body {
            headers = headers.filter { $0.key.caseInsensitiveCompare("Content-Type") != .orderedSame }
        }

        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            parts.append("-H \(shellQuote("\(name): \(value)"))")
        }

        switch model.body {
        case .none:
            break
        case .raw(let content, let contentType):
            // Gönderilenle aynı: yorumlar dışa aktarılmaz.
            let resolved = try resolver.resolve(RequestBodyComments.sendable(content, contentType: contentType))
            if !resolved.isEmpty {
                parts.append("--data-raw \(shellQuote(resolved))")
            }
        case .formURLEncoded(let fields):
            for field in fields where field.enabled && !field.key.isEmpty {
                let pair = "\(try resolver.resolve(field.key))=\(try resolver.resolve(field.value))"
                parts.append("--data-urlencode \(shellQuote(pair))")
            }
        case .multipartForm(let fields):
            for field in fields where field.enabled && !field.key.isEmpty {
                let pair = "\(try resolver.resolve(field.key))=\(try resolver.resolve(field.value))"
                parts.append("-F \(shellQuote(pair))")
            }
        }

        return parts.joined(separator: " \\\n  ")
    }

    /// Tek tırnaklı shell alıntısı; içerideki tek tırnaklar '\'' ile kaçırılır.
    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
