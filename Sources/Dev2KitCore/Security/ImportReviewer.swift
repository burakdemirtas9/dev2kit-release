import Foundation

/// İçe aktarmadan önce bulunan durum.
public struct ImportFinding: Hashable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        /// İstek aktarılmaz.
        case block
        /// Aktarılır, kullanıcı görmüş olur.
        case warn
        /// Bilgi: veri kaybı ya da dikkat edilmesi gereken içerik.
        case info

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let severity: Severity
    public let title: String
    public let detail: String

    public init(severity: Severity, title: String, detail: String) {
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public struct RequestReview: Identifiable, Sendable {
    public let request: RequestModel
    public let findings: [ImportFinding]

    public var id: UUID { request.id }
    public var isBlocked: Bool { findings.contains { $0.severity == .block } }
    public var worstSeverity: ImportFinding.Severity? { findings.map(\.severity).min() }
}

/// Bir koleksiyonun (ya da tek isteğin) içe aktarma incelemesi.
public struct CollectionReview: Identifiable, Sendable {
    public let id = UUID()
    public let collection: CollectionModel
    public let requests: [RequestReview]
    /// Dönüştürme sırasında oluşan notlar (atlanan script, desteklenmeyen auth…).
    public let notes: [String]

    /// Aktarılacak hali: kesin engelli istekler çıkarılmış.
    public var importableCollection: CollectionModel {
        var copy = collection
        let blocked = Set(requests.filter(\.isBlocked).map(\.id))
        copy.requests.removeAll { blocked.contains($0.id) }
        return copy
    }

    public var blockedCount: Int { requests.filter(\.isBlocked).count }
    public var importableCount: Int { requests.count - blockedCount }

    /// Hiç bulgu ve not yoksa inceleme ekranı gösterilmeden aktarılabilir.
    public var isClean: Bool { notes.isEmpty && requests.allSatisfy { $0.findings.isEmpty } }
}

/// İçe aktarılan içeriği ağa hiç çıkmadan, şablon haliyle inceler.
///
/// Gönderim anındaki `RequestInspector`'dan farkı: değişkenler henüz çözülmez
/// (içe aktarılan koleksiyonun environment'ı yoktur). Adres ya da host
/// `{{…}}` ile geliyorsa host kuralları atlanır; o istek gönderilirken zaten
/// çözülmüş haliyle yeniden denetlenir.
public enum ImportReviewer {
    public struct Context: Sendable {
        public let policy: HostPolicyState
        /// Kullanıcının vault'undaki secret adları. İçe aktarılan bir isteğin
        /// bunlardan birini kullanması, dışarıdan gelen içeriğin kullanıcının
        /// secret'ını bir yere göndermesi demektir.
        public let vaultSecretNames: Set<String>

        public init(policy: HostPolicyState, vaultSecretNames: Set<String>) {
            self.policy = policy
            self.vaultSecretNames = vaultSecretNames
        }
    }

    /// İçe aktarılabilecek en büyük dosya. Koleksiyonlar birkaç MB'ı nadiren
    /// geçer; sınır, belleği dolduracak bir dosyanın uygulamayı kilitlemesini önler.
    public static let maxImportBytes = 20 * 1024 * 1024

    public static func review(collection: CollectionModel, notes: [String], context: Context) -> CollectionReview {
        CollectionReview(
            collection: collection,
            requests: collection.requests.map { RequestReview(request: $0, findings: review($0, context: context)) },
            notes: notes
        )
    }

    public static func review(_ request: RequestModel, context: Context) -> [ImportFinding] {
        var findings: [ImportFinding] = []
        let target = LiteralTarget(request.url)

        // MARK: Kesin engeller

        if let scheme = target.scheme, scheme != "http", scheme != "https" {
            findings.append(ImportFinding(
                severity: .block,
                title: "Desteklenmeyen adres türü",
                detail: "\"\(scheme)://\" adreslerine istek gönderilmez; bu istek aktarılmaz."
            ))
        }
        if let host = target.host, let violation = context.policy.violation(for: URL(string: "https://\(host)")) {
            findings.append(ImportFinding(severity: .block, title: "Yönetici politikası", detail: violation))
        }
        if RequestInspector.containsHiddenCharacters(request.url, allowTab: false)
            || request.headers.contains(where: {
                RequestInspector.containsHiddenCharacters($0.key, allowTab: false)
                    || RequestInspector.containsHiddenCharacters($0.value, allowTab: true)
            }) {
            findings.append(ImportFinding(
                severity: .block,
                title: "Görünmez karakter",
                detail: "Adres ya da bir başlık görünmeyen, satır sonu ya da yön değiştiren karakter içeriyor. Gerçek hedefi ya da ek başlıkları gizlemek için kullanılabilir."
            ))
        }

        // MARK: Dikkat

        let secrets = SecretReferences.names(in: request, environment: nil)
        let vaultSecrets = secrets.intersection(context.vaultSecretNames)
        if !vaultSecrets.isEmpty {
            let destination = target.host.map { "\($0) adresine" } ?? "değişkenle belirlenen bir adrese"
            findings.append(ImportFinding(
                severity: .warn,
                title: "Vault'undaki secret'ı kullanıyor",
                detail: "\(vaultSecrets.sorted().joined(separator: ", ")) \(destination) gönderilecek. Dışarıdan gelen bir koleksiyonsa hedefin güvenilir olduğundan emin ol."
            ))
        }

        let plaintext = plaintextCredentials(in: request)
        if !plaintext.isEmpty {
            findings.append(ImportFinding(
                severity: .warn,
                title: "Düz metin kimlik bilgisi",
                detail: "\(plaintext.joined(separator: ", ")) düz metin olarak koleksiyona yazılacak. Secrets'a ekleyip {{secret:isim}} ile referans vermen önerilir."
            ))
        }

        if let host = target.host {
            let carriesCredentials = request.auth != .none || !secrets.isEmpty || !plaintext.isEmpty
            if target.scheme == "http", !RequestInspector.isLoopback(host), carriesCredentials {
                findings.append(ImportFinding(
                    severity: .warn,
                    title: "Kimlik bilgisi şifresiz gidecek",
                    detail: "\(host) adresine http (şifresiz) ile kimlik bilgisi gönderiyor."
                ))
            }
            if RequestInspector.isMetadataHost(host) {
                findings.append(ImportFinding(
                    severity: .warn,
                    title: "Bulut metadata adresi",
                    detail: "\(host) bulut sunucularının kimlik bilgisi dağıttığı adres; paylaşılan bir koleksiyonda beklenmez."
                ))
            }
            if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) || !host.unicodeScalars.allSatisfy(\.isASCII) {
                findings.append(ImportFinding(
                    severity: .warn,
                    title: "Benzer görünen alan adı",
                    detail: "\(host) Latin dışı harfler içeriyor; tanıdık bir adrese benzeyen sahte alan adı olabilir."
                ))
            }
        }
        if target.hasUserInfo {
            findings.append(ImportFinding(
                severity: .warn,
                title: "Adreste kullanıcı bilgisi",
                detail: "Adres kullanıcı adı/parola içeriyor (kullanici:parola@host)."
            ))
        }

        // MARK: Bilgi

        let personal = request.headers.filter { entry in
            entry.enabled && !entry.value.contains("{{")
                && HeaderClassifier.classify(name: entry.key, value: entry.value).sensitiveKind == .personal
        }
        if !personal.isEmpty {
            findings.append(ImportFinding(
                severity: .info,
                title: "Kişisel veri",
                detail: "\(personal.map(\.key).joined(separator: ", ")) başlıkları kişisel veri içeriyor olabilir (KVKK); koleksiyona ve dışa aktarımlara düz metin yazılır."
            ))
        }
        return findings.sorted { $0.severity < $1.severity }
    }

    // MARK: - Düz metin kimlik bilgisi

    /// Şablon (`{{…}}`) içermeyen kimlik bilgilerinin nerede olduğu.
    static func plaintextCredentials(in request: RequestModel) -> [String] {
        var places: [String] = []
        func isLiteral(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespaces).isEmpty && !value.contains("{{")
        }
        switch request.auth {
        case .basic(_, let password) where isLiteral(password): places.append("Basic auth parolası")
        case .bearer(let token) where isLiteral(token): places.append("Bearer token")
        case .apiKey(let key, let value, _) where isLiteral(value): places.append("API key (\(key))")
        default: break
        }
        for entry in request.headers where entry.enabled && isLiteral(entry.value) {
            if HeaderClassifier.classify(name: entry.key, value: entry.value).sensitiveKind == .credential {
                places.append("\"\(entry.key)\" başlığı")
            }
        }
        for entry in request.queryParams where entry.enabled && isLiteral(entry.value) {
            if looksLikeSecretField(entry.key, value: entry.value) { places.append("\"\(entry.key)\" query parametresi") }
        }
        switch request.body {
        case .raw(let content, _):
            if containsTokenPattern(content) { places.append("gövde") }
        case .formURLEncoded(let fields), .multipartForm(let fields):
            for field in fields where field.enabled && isLiteral(field.value) && looksLikeSecretField(field.key, value: field.value) {
                places.append("\"\(field.key)\" form alanı")
            }
        case .none:
            break
        }
        if containsTokenPattern(request.url) { places.append("adres") }
        return places
    }

    private static func looksLikeSecretField(_ name: String, value: String) -> Bool {
        let lower = name.lowercased()
        if containsTokenPattern(value) { return true }
        let keywords = ["token", "secret", "password", "passwd", "apikey", "api_key", "api-key", "access_key", "client_secret"]
        return keywords.contains(where: lower.contains) && (HeaderClassifier.looksOpaque(value) || lower.contains("pass"))
    }

    /// Bilinen token biçimleri: JWT, AWS erişim anahtarı, özel anahtar bloğu,
    /// GitHub ve Slack token'ları.
    static func containsTokenPattern(_ text: String) -> Bool {
        let patterns = [
            #"eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]*"#,
            #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#,
            #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: - Şablondan okunabilen hedef

    /// Adresin değişken içermeyen kısmından okunabilen şema ve host.
    /// `{{baseUrl}}/x` gibi adreslerde ikisi de bilinmez (nil).
    struct LiteralTarget {
        let scheme: String?
        let host: String?
        let hasUserInfo: Bool

        init(_ raw: String) {
            let url = raw.trimmingCharacters(in: .whitespaces)
            guard let separator = url.range(of: "://") else {
                (scheme, host, hasUserInfo) = (nil, nil, false)
                return
            }
            let schemePart = String(url[..<separator.lowerBound])
            scheme = schemePart.contains("{{") ? nil : schemePart.lowercased()
            let rest = url[separator.upperBound...]
            let authority = String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
            hasUserInfo = authority.contains("@") && !authority.contains("{{")
            let hostPart = authority.split(separator: "@").last.map(String.init) ?? authority
            if hostPart.contains("{{") || hostPart.isEmpty {
                host = nil
            } else {
                // Port ve IPv6 köşeli parantezleri atılır.
                let withoutPort = hostPart.hasPrefix("[")
                    ? String(hostPart.dropFirst().prefix { $0 != "]" })
                    : String(hostPart.split(separator: ":").first ?? "")
                host = HostPolicy.normalize(withoutPort)
            }
        }
    }
}
