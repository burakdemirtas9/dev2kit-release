import Foundation

/// Gönderimden önce bulunan güvenlik sorunu.
public struct SecurityFinding: Hashable, Identifiable, Sendable {
    public enum Severity: Sendable {
        /// Gönderilmez; kullanıcı geçersiz kılamaz.
        case block
        /// Gönderim durdurulur; kullanıcı görüp "Yine de gönder" diyebilir.
        case warn
    }

    public let severity: Severity
    public let title: String
    public let detail: String
    /// Uyarının kalıcı onay anahtarı. Onaylanan durum (aynı host, aynı secret)
    /// bir daha sorulmaz; farklı host ya da secret yeni bir anahtardır.
    public let approvalKey: String?

    public var id: String { approvalKey ?? "\(title)|\(detail)" }

    public init(severity: Severity, title: String, detail: String, approvalKey: String? = nil) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.approvalKey = approvalKey
    }
}

/// İsteğin güvenlik kurallarından geçip geçmediğine karar veren saf mantık.
///
/// İki girdi birlikte kullanılır:
/// - **Şablon** (`RequestModel`): hangi secret'ın nerede kullanıldığı yalnızca
///   burada görünür; çözülmüş değer secret'ın kendisidir, kaynağı değil.
/// - **Çözülmüş istek** (`URLRequest`): gerçek host, şema ve başlıklar.
///   `{{baseUrl}}` gibi bir değişkenin arkasına saklanan adres de böylece denetlenir.
public enum RequestInspector {
    public static func inspect(
        model: RequestModel,
        request: URLRequest,
        environment: EnvironmentModel?,
        policy: HostPolicyState
    ) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        let url = request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        let host = HostPolicy.normalize(url?.host ?? "")

        // MARK: Kesin engeller

        if scheme != "http" && scheme != "https" {
            findings.append(SecurityFinding(
                severity: .block,
                title: "Desteklenmeyen adres türü",
                detail: "Yalnızca http ve https adreslerine istek gönderilir; \"\(scheme.isEmpty ? "(şema yok)" : scheme)\" kabul edilmez."
            ))
        }
        if let violation = policy.violation(for: url) {
            findings.append(SecurityFinding(severity: .block, title: "Yönetici politikası", detail: violation))
        }
        if containsHiddenCharacters(model.url, allowTab: false) {
            findings.append(SecurityFinding(
                severity: .block,
                title: "Adreste görünmez karakter",
                detail: "Adres, ekranda görünmeyen ya da metnin yönünü değiştiren karakterler içeriyor. Gerçek hedefi gizlemek için kullanılabilir."
            ))
        }
        if let header = injectedHeader(in: model) {
            findings.append(headerInjectionFinding(header))
        }

        // Host'u belirsiz bir istek için uyarı üretmenin anlamı yok; zaten engellendi.
        guard scheme == "http" || scheme == "https", !host.isEmpty else { return findings }

        // MARK: Uyarılar (durdur, kullanıcı onaylarsa gönder)

        let secrets = SecretReferences.names(in: model, environment: environment)

        if scheme == "http", !isLoopback(host), carriesCredentials(model: model, request: request, secrets: secrets) {
            findings.append(SecurityFinding(
                severity: .warn,
                title: "Kimlik bilgisi şifresiz gidiyor",
                detail: "\(host) adresine http (şifresiz) ile kimlik bilgisi ya da secret gönderilecek. Ağdaki herkes okuyabilir.",
                approvalKey: "cleartext|\(host)"
            ))
        }
        if isMetadataHost(host) {
            findings.append(SecurityFinding(
                severity: .warn,
                title: "Bulut metadata adresi",
                detail: "\(host) bulut sunucularının kimlik bilgisi dağıttığı adres. İçe aktarılmış bir istekte görülmesi beklenmez.",
                approvalKey: "metadata|\(host)"
            ))
        }
        if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") })
            || !host.unicodeScalars.allSatisfy(\.isASCII) {
            findings.append(SecurityFinding(
                severity: .warn,
                title: "Benzer görünen alan adı",
                detail: "\(host) Latin dışı harfler içeriyor. Tanıdık bir adrese benzeyen sahte alan adları bu yolla yapılır.",
                approvalKey: "idn|\(host)"
            ))
        }
        if url?.user != nil {
            findings.append(SecurityFinding(
                severity: .warn,
                title: "Adreste kullanıcı bilgisi",
                detail: "Adres kullanıcı adı/parola içeriyor (kullanici:parola@host). Geçmişe, sunucu ve proxy loglarına yazılır; Auth sekmesini kullan.",
                approvalKey: "userinfo|\(host)"
            ))
        }
        let secretsInURL = SecretReferences.namesInURL(of: model, environment: environment)
        if !secretsInURL.isEmpty {
            findings.append(SecurityFinding(
                severity: .warn,
                title: "Secret adreste",
                detail: "\(secretsInURL.sorted().joined(separator: ", ")) adreste ya da query'de gidiyor. Adresler sunucu ve proxy loglarına yazılır; başlıkta göndermek daha güvenli.",
                approvalKey: "secret-in-url|\(host)|\(secretsInURL.sorted().joined(separator: ","))"
            ))
        }
        for name in secrets.sorted() {
            findings.append(SecurityFinding(
                severity: .warn,
                title: "Secret yeni bir host'a gidiyor",
                detail: "\"\(name)\" ilk kez \(host) adresine gönderilecek. Onaylarsan bu ikili bir daha sorulmaz.",
                approvalKey: "secret-host|\(name)|\(host)"
            ))
        }
        return findings
    }

    /// Engel varsa `securityBlocked`, onaylanmamış uyarı varsa `needsApproval`
    /// fırlatır. Engel her zaman önce gelir: onay, engeli aşmanın yolu değildir.
    public static func enforce(_ findings: [SecurityFinding], approved: Set<String>) throws {
        let blocks = findings.filter { $0.severity == .block }
        guard blocks.isEmpty else { throw RequestEngineError.securityBlocked(blocks) }
        let pending = findings.filter { finding in
            finding.severity == .warn && !approved.contains(finding.approvalKey ?? "")
        }
        guard pending.isEmpty else { throw RequestEngineError.needsApproval(pending) }
    }

    // MARK: - Yardımcılar

    /// CR, LF, NUL, diğer kontrol karakterleri ve biçim karakterleri
    /// (sıfır genişlikli boşluk, U+202E gibi yön değiştiriciler).
    static func containsHiddenCharacters(_ text: String, allowTab: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            if allowTab, scalar == "\t" { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// Şablondaki başlıklar. Secret ya da değişkenden gelen değerler gönderim
    /// anında `RequestEngine.setHeader` içinde, çözülmüş halleriyle denetlenir.
    private static func injectedHeader(in model: RequestModel) -> String? {
        model.headers.first { entry in
            entry.enabled && (containsHiddenCharacters(entry.key, allowTab: false)
                || containsHiddenCharacters(entry.value, allowTab: true))
        }?.key
    }

    static func headerInjectionFinding(_ header: String) -> SecurityFinding {
        // Adın kendisi de görünmez karakter içerebilir; gösterirken temizlenir.
        let visible = String(String.UnicodeScalarView(header.unicodeScalars.filter {
            !containsHiddenCharacters(String($0), allowTab: false)
        }))
        return SecurityFinding(
            severity: .block,
            title: "Başlıkta satır sonu ya da görünmez karakter",
            detail: "\"\(visible)\" başlığı satır sonu (CR/LF) ya da görünmez karakter içeriyor. Bu, isteğe başka başlıklar eklemek için kullanılabilir."
        )
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
    }

    static func isMetadataHost(_ host: String) -> Bool {
        let known: Set<String> = ["169.254.169.254", "fd00:ec2::254", "metadata.google.internal", "metadata", "100.100.100.200"]
        return known.contains(host) || host.hasPrefix("169.254.")
    }

    private static func carriesCredentials(model: RequestModel, request: URLRequest, secrets: Set<String>) -> Bool {
        if model.auth != .none || !secrets.isEmpty { return true }
        let headers = request.allHTTPHeaderFields ?? [:]
        return headers.keys.contains { ["authorization", "cookie", "proxy-authorization"].contains($0.lowercased()) }
    }
}

/// Bir isteğin kullandığı secret adları (`{{secret:isim}}`), environment
/// değişkenleri üzerinden dolaylı kullanım ve OAuth2 token'ı dahil.
public enum SecretReferences {
    private static let pattern = #/\{\{\s*([^{}]+?)\s*\}\}/#
    private static let maxDepth = 5

    public static func names(in model: RequestModel, environment: EnvironmentModel?) -> Set<String> {
        var names = Set<String>()
        if case .oauth2(let config) = model.auth { names.insert(config.tokenSecretName) }
        let variables = variableMap(environment)
        for text in templateTexts(of: model) { collect(from: text, variables: variables, depth: 0, into: &names) }
        return names
    }

    /// İsteğin doğrudan ya da başka değişkenler üzerinden kullandığı değişken adları
    /// (`{{secret:…}}` hariç). Tanımsız değişkenler de dahildir.
    public static func variableNames(in model: RequestModel, environment: EnvironmentModel?) -> Set<String> {
        var names = Set<String>()
        let variables = variableMap(environment)
        for text in templateTexts(of: model) { collectVariables(from: text, variables: variables, depth: 0, into: &names) }
        return names
    }

    /// Gönderimde çözülen tüm metin alanları (devre dışı satırlar hariç).
    private static func templateTexts(of model: RequestModel) -> [String] {
        var texts = [model.url]
        for entry in model.headers where entry.enabled { texts += [entry.key, entry.value] }
        for entry in model.queryParams where entry.enabled { texts += [entry.key, entry.value] }
        switch model.body {
        case .none: break
        case .raw(let content, _): texts.append(content)
        case .formURLEncoded(let fields), .multipartForm(let fields):
            for field in fields where field.enabled { texts += [field.key, field.value] }
        }
        switch model.auth {
        case .none, .oauth2: break
        case .basic(let username, let password): texts += [username, password]
        case .bearer(let token): texts.append(token)
        case .apiKey(let key, let value, _): texts += [key, value]
        }
        return texts
    }

    /// Adreste ya da query'de (API key query auth'u dahil) kullanılan secret'lar.
    public static func namesInURL(of model: RequestModel, environment: EnvironmentModel?) -> Set<String> {
        var texts = [model.url]
        for entry in model.queryParams where entry.enabled { texts += [entry.key, entry.value] }
        if case .apiKey(let key, let value, .queryParam) = model.auth { texts += [key, value] }
        var names = Set<String>()
        let variables = variableMap(environment)
        for text in texts { collect(from: text, variables: variables, depth: 0, into: &names) }
        return names
    }

    private static func variableMap(_ environment: EnvironmentModel?) -> [String: String] {
        var map: [String: String] = [:]
        for entry in environment?.variables ?? [] where entry.enabled && !entry.key.isEmpty {
            map[entry.key] = entry.value
        }
        return map
    }

    private static func collectVariables(from text: String, variables: [String: String], depth: Int, into names: inout Set<String>) {
        guard depth < maxDepth, text.contains("{{") else { return }
        for match in text.matches(of: pattern) {
            let token = String(match.1)
            guard !token.hasPrefix("secret:") else { continue }
            names.insert(token)
            if let value = variables[token] {
                collectVariables(from: value, variables: variables, depth: depth + 1, into: &names)
            }
        }
    }

    private static func collect(from text: String, variables: [String: String], depth: Int, into names: inout Set<String>) {
        guard depth < maxDepth, text.contains("{{") else { return }
        for match in text.matches(of: pattern) {
            let token = String(match.1)
            if token.hasPrefix("secret:") {
                names.insert(String(token.dropFirst("secret:".count)).trimmingCharacters(in: .whitespaces))
            } else if let value = variables[token] {
                collect(from: value, variables: variables, depth: depth + 1, into: &names)
            }
        }
    }
}
