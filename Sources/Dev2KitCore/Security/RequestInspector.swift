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
                title: L10n.t("finding.scheme.title"),
                detail: L10n.t("finding.scheme.detail", scheme.isEmpty ? L10n.t("finding.scheme.none") : scheme)
            ))
        }
        if let violation = policy.violation(for: url) {
            findings.append(SecurityFinding(severity: .block, title: L10n.t("finding.policy.title"), detail: violation))
        }
        if containsHiddenCharacters(model.url, allowTab: false) {
            findings.append(SecurityFinding(
                severity: .block,
                title: L10n.t("finding.hiddenURL.title"),
                detail: L10n.t("finding.hiddenURL.detail")
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
                title: L10n.t("finding.cleartext.title"),
                detail: L10n.t("finding.cleartext.detail", host),
                approvalKey: "cleartext|\(host)"
            ))
        }
        if isMetadataHost(host) {
            findings.append(SecurityFinding(
                severity: .warn,
                title: L10n.t("finding.metadata.title"),
                detail: L10n.t("finding.metadata.detail", host),
                approvalKey: "metadata|\(host)"
            ))
        }
        if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") })
            || !host.unicodeScalars.allSatisfy(\.isASCII) {
            findings.append(SecurityFinding(
                severity: .warn,
                title: L10n.t("finding.idn.title"),
                detail: L10n.t("finding.idn.detail", host),
                approvalKey: "idn|\(host)"
            ))
        }
        if url?.user != nil {
            findings.append(SecurityFinding(
                severity: .warn,
                title: L10n.t("finding.userinfo.title"),
                detail: L10n.t("finding.userinfo.detail"),
                approvalKey: "userinfo|\(host)"
            ))
        }
        let secretsInURL = SecretReferences.namesInURL(of: model, environment: environment)
        if !secretsInURL.isEmpty {
            findings.append(SecurityFinding(
                severity: .warn,
                title: L10n.t("finding.secretInURL.title"),
                detail: L10n.t("finding.secretInURL.detail", secretsInURL.sorted().joined(separator: ", ")),
                approvalKey: "secret-in-url|\(host)|\(secretsInURL.sorted().joined(separator: ","))"
            ))
        }
        for name in secrets.sorted() {
            findings.append(SecurityFinding(
                severity: .warn,
                title: L10n.t("finding.secretNewHost.title"),
                detail: L10n.t("finding.secretNewHost.detail", name, host),
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
            title: L10n.t("finding.headerInjection.title"),
            detail: L10n.t("finding.headerInjection.detail", visible)
        )
    }

    /// `127.` öneki yalnızca gerçek IPv4 adresinde loopback demektir:
    /// `127.evil.com` bir DNS adıdır ve şifresiz http uyarısını atlatıyordu
    /// (güvenlik taraması S1).
    static func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower == "::1" { return true }
        let octets = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { octet in
            (1...3).contains(octet.count) && octet.allSatisfy(\.isASCII) && octet.allSatisfy(\.isNumber)
                && (Int(octet).map { $0 <= 255 } ?? false)
        }
    }

    static func isMetadataHost(_ host: String) -> Bool {
        let knownNames: Set<String> = ["metadata.google.internal", "metadata"]
        if knownNames.contains(host.lowercased()) { return true }
        // IP olarak karşılaştırılır: URLSession `2852039166`, `0xa9fea9fe`,
        // `169.254.43518` ve `[::ffff:169.254.169.254]` yazımlarına da
        // bağlanıyor (ölçüldü); metin eşleşmesi onları kaçırıyordu (güvenlik taraması S7).
        guard let address = ipAddressBytes(host) else { return false }
        if address.count == 4, address[0] == 169, address[1] == 254 { return true }   // 169.254.0.0/16
        let knownAddresses = ["100.100.100.200", "fd00:ec2::254"].compactMap(ipAddressBytes)
        return knownAddresses.contains(address)
    }

    /// Sayısal host'un baytları (IPv4: 4, IPv6: 16; IPv4-mapped IPv6 → 4).
    /// Ayrıştırma sistemin kendi kurallarıyla (`inet_aton`, `inet_pton`):
    /// bağlantıyı kuran taraf da onları kullanıyor. Ad ise `nil`.
    static func ipAddressBytes(_ host: String) -> [UInt8]? {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard !bare.isEmpty, !bare.contains(where: \.isWhitespace) else { return nil }
        var v4 = in_addr()
        if inet_aton(bare, &v4) == 1 {
            return withUnsafeBytes(of: v4.s_addr) { Array($0) }   // ağ bayt sırası
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, bare, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return Array(bytes[12...])
        }
        return bytes
    }

    /// Şifresiz kanalda kimlik bilgisi gidiyor mu. Önceden yalnızca
    /// Authorization/Cookie başlığına bakılıyordu; düz değerli `X-Api-Key` ya
    /// da sorgudaki token uyarısız gidiyordu (güvenlik taraması S6).
    /// Başlık ve sorgu adları aynı sınıflandırıcıdan geçer.
    private static func carriesCredentials(model: RequestModel, request: URLRequest, secrets: Set<String>) -> Bool {
        if model.auth != .none || !secrets.isEmpty { return true }
        let isCredential = { (name: String, value: String) in
            HeaderClassifier.classify(name: name, value: value).sensitiveKind == .credential
        }
        if (request.allHTTPHeaderFields ?? [:]).contains(where: { isCredential($0.key, $0.value) }) { return true }
        let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return query.contains { isCredential($0.name, $0.value ?? "") }
    }
}

/// Bir isteğin kullandığı secret adları (`{{secret:isim}}`), environment
/// değişkenleri üzerinden dolaylı kullanım ve OAuth2 token'ı dahil.
public enum SecretReferences {
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
        // GET'te gövde gönderilmez (`RequestEngine.attachBody`): içindeki
        // değişken token almasın, tanımsızsa isteği durdurmasın.
        switch model.method.allowsBody ? model.body : .none {
        case .none: break
        case .raw(let content, let contentType):
            // Yorumdaki {{değişken}} gönderilmez; token almasın, hata vermesin.
            texts.append(RequestBodyComments.sendable(content, contentType: contentType))
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
        for match in TemplateScanner.matches(in: text) {
            let token = String(match.name)
            guard !token.hasPrefix("secret:") else { continue }
            names.insert(token)
            if let value = variables[token] {
                collectVariables(from: value, variables: variables, depth: depth + 1, into: &names)
            }
        }
    }

    private static func collect(from text: String, variables: [String: String], depth: Int, into names: inout Set<String>) {
        guard depth < maxDepth, text.contains("{{") else { return }
        for match in TemplateScanner.matches(in: text) {
            let token = String(match.name)
            if token.hasPrefix("secret:") {
                names.insert(String(token.dropFirst("secret:".count)).trimmingCharacters(in: .whitespaces))
            } else if let value = variables[token] {
                collect(from: value, variables: variables, depth: depth + 1, into: &names)
            }
        }
    }
}
