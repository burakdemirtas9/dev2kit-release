import Foundation

/// Token Factory kuralları: hangi istek hangi token'ı üretir, bir istek
/// hangi token'lara ihtiyaç duyar, gönderimde değişkenler nasıl bağlanır ve
/// yapılandırmada neler yanlış.
///
/// Token Factory isteği sıradan bir REST isteğidir (metot, başlık, gövde
/// serbest); tek farkı yanıtından bir alanın bir değişkene yazılmasıdır.
/// Token değeri yalnızca bellekte tutulur, hiçbir zaman diske yazılmaz.
public enum TokenFactory {
    /// Bir değişkeni üreten Token Factory isteği.
    public struct Source: Hashable, Sendable {
        public let request: RequestModel
        public let output: TokenOutput

        public var variable: String { output.trimmedVariableName }
        /// Gönderimde token'ın göründüğü secret adı (bkz. `environmentForSend`).
        public var secretName: String { TokenFactory.secretName(for: variable) }
    }

    /// Environment seçili değilken token değişkenlerini taşımak için kurulan
    /// geçici environment'ın kimliği. `RequestEngine.Scope` bunu "environment
    /// yok" sayar: çerezler normal "default" kavanozunda kalır.
    public static let unboundEnvironmentID = UUID(uuidString: "00000000-0000-0000-0000-00000000F4C7")!

    /// Token'ın gönderim sırasında bağlandığı secret adı.
    ///
    /// Değişken `{{secret:…}}` olarak bağlanır ki güvenlik kontrolleri token'ı
    /// secret olarak tanısın (şifresiz http uyarısı, yeni host onayı) ve
    /// geçmişe/loglara düz değer olarak düşmesin. Vault'ta böyle bir kayıt
    /// yoktur; değer bellekteki token'dan gelir (`OverlaySecretStore`).
    public static func secretName(for variable: String) -> String { "token-factory/\(variable)" }

    /// Bu environment etkinken geçerli token kaynakları.
    ///
    /// Aynı değişkeni üreten birden çok kaynak varsa ilk geçerli olan alınır;
    /// bu durum `problems` ile ayrıca kullanıcıya bildirilir.
    public static func sources(in requests: [RequestModel], environment: EnvironmentModel?) -> [Source] {
        var seen = Set<String>()
        return requests.compactMap { request in
            let output = request.tokenOutput ?? TokenOutput()
            let source = Source(request: request, output: output)
            guard output.applies(to: environment), isValidVariableName(source.variable),
                  seen.insert(source.variable).inserted else { return nil }
            return source
        }
    }

    /// İsteğin doğrudan ya da başka değişkenler üzerinden kullandığı token'lar.
    public static func referenced(
        by model: RequestModel,
        environment: EnvironmentModel?,
        sources: [Source]
    ) -> [Source] {
        guard !sources.isEmpty else { return [] }
        let names = SecretReferences.variableNames(in: model, environment: environment)
        return sources.filter { names.contains($0.variable) }
    }

    /// Gönderim için environment: token değişkenleri `{{secret:<secretName>}}`
    /// değerini alır. Aynı adlı environment değişkeni varsa TOKEN kazanır
    /// (arayüz bunu `shadowedVariables` ile kullanıcıya söyler).
    public static func environmentForSend(_ environment: EnvironmentModel?, sources: [Source]) -> EnvironmentModel? {
        guard !sources.isEmpty else { return environment }
        var copy = environment ?? EnvironmentModel(id: unboundEnvironmentID, name: "")
        let names = Set(sources.map(\.variable))
        copy.variables.removeAll { names.contains($0.key) }
        copy.variables += sources.map { KeyValueEntry(key: $0.variable, value: "{{secret:\($0.secretName)}}") }
        return copy
    }

    /// "Yine de gönder (token olmadan)" için environment: token alınamadı ve
    /// kullanıcı isteği bilerek token'sız göndermek istiyor.
    ///
    /// Environment'ta aynı adlı (etkin) değişken varsa o kullanılır — token
    /// yokken kullanıcının kendi koyduğu değer en makul yedek. Yoksa değişken
    /// BOŞ bağlanır; tanımsız değişken hatasıyla yeniden durdurmak, kullanıcının
    /// az önce verdiği "yine de gönder" kararını boşa çıkarırdı.
    public static func environmentWithoutTokens(_ environment: EnvironmentModel?, sources: [Source]) -> EnvironmentModel? {
        guard !sources.isEmpty else { return environment }
        var copy = environment ?? EnvironmentModel(id: unboundEnvironmentID, name: "")
        let defined = Set(copy.variables.filter { $0.enabled && !$0.key.isEmpty }.map(\.key))
        for source in sources where !defined.contains(source.variable) {
            copy.variables.append(KeyValueEntry(key: source.variable, value: ""))
        }
        return copy
    }

    /// Environment'taki, Token Factory tarafından ezilen değişken adları.
    public static func shadowedVariables(in environment: EnvironmentModel?, sources: [Source]) -> [String] {
        guard let environment else { return [] }
        let names = Set(sources.map(\.variable))
        return environment.variables
            .filter { $0.enabled && names.contains($0.key) }
            .map(\.key)
    }

    // MARK: - Token servisinin yanıtı

    /// Yanıttan alınan token.
    public struct IssuedToken: Equatable, Sendable {
        public let value: String
        /// Bilinmiyorsa `nil` (bkz. `TokenLifetime`).
        public let expiresAt: Date?

        public init(value: String, expiresAt: Date?) {
            self.value = value
            self.expiresAt = expiresAt
        }

        public func needsRefresh(now: Date = Date()) -> Bool {
            TokenLifetime.needsRefresh(expiresAt: expiresAt, now: now)
        }
    }

    public enum IssueFailure: Error, Equatable, LocalizedError {
        /// Token servisi 2xx dışı döndü. `detail`: servisin kendi açıklaması.
        case httpStatus(Int, detail: String?)
        case field(TokenField.Failure, statusCode: Int)

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let status, let detail):
                return L10n.t("tokenFactory.httpStatus", String(status)) + (detail.map { ": \($0)" } ?? "")
            case .field(let failure, let status):
                return "\(failure.localizedDescription) (HTTP \(status))"
            }
        }
    }

    /// Token servisinin yanıtını değerlendirir.
    ///
    /// 2xx dışı yanıt token sayılmaz: bazı servisler hata gövdesinde de
    /// `access_token: null` ya da eski bir alan döndürebiliyor.
    public static func issue(
        statusCode: Int,
        body: Data,
        output: TokenOutput,
        receivedAt: Date = Date()
    ) throws -> IssuedToken {
        guard (200..<300).contains(statusCode) else {
            throw IssueFailure.httpStatus(statusCode, detail: errorDetail(in: body))
        }
        let value: String
        do {
            value = try TokenField.value(at: output.responseField, in: body)
        } catch let failure as TokenField.Failure {
            throw IssueFailure.field(failure, statusCode: statusCode)
        }
        return IssuedToken(
            value: value,
            expiresAt: TokenLifetime.expiry(token: value, responseBody: body, receivedAt: receivedAt)
        )
    }

    /// Hata gövdesindeki açıklama: OAuth2 (`error`, `error_description`) ya da
    /// yaygın `message` / `errorMessage` alanları. Gövdenin kendisi
    /// gösterilmez: hata yanıtları da kişisel veri ya da yankılanan kimlik
    /// bilgisi taşıyabilir. Uzun metin kısaltılır.
    static func errorDetail(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let text: (String) -> String? = { key in
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let detail: String?
        if let error = text("error") {
            detail = text("error_description").map { "\(error) — \($0)" } ?? error
        } else {
            detail = text("errorMessage") ?? text("message") ?? text("error_description")
        }
        guard let detail else { return nil }
        return detail.count > 200 ? String(detail.prefix(200)) + "…" : detail
    }

    // MARK: - Yapılandırma sorunları

    public enum Problem: Hashable, Sendable, CustomStringConvertible {
        /// Değişken adı boş ya da `{{…}}` içinde kullanılamayacak karakter taşıyor.
        case invalidVariableName(request: String, name: String)
        case emptyResponseField(request: String)
        /// Aynı environment'ta iki istek aynı değişkeni üretiyor.
        case duplicateVariable(name: String, requests: [String])
        /// Token isteği kendisi bir Token Factory değişkeni kullanıyor.
        /// Zincirleme bilerek desteklenmiyor: döngü ve "hangisi önce" belirsizliği.
        case usesFactoryVariable(request: String, variable: String)

        /// Bu sorun adı verilen isteği ilgilendiriyor mu.
        public func involves(request name: String) -> Bool {
            switch self {
            case .invalidVariableName(let request, _), .emptyResponseField(let request),
                 .usesFactoryVariable(let request, _):
                return request == name
            case .duplicateVariable(_, let requests):
                return requests.contains(name)
            }
        }

        public var description: String {
            switch self {
            case .invalidVariableName(let request, let name):
                return L10n.t("tokenFactory.badVariable", request, name)
            case .emptyResponseField(let request):
                return L10n.t("tokenFactory.emptyField", request)
            case .duplicateVariable(let name, let requests):
                return L10n.t("tokenFactory.duplicate", name, requests.joined(separator: ", "))
            case .usesFactoryVariable(let request, let variable):
                return L10n.t("tokenFactory.selfReference", request, variable)
            }
        }
    }

    /// Bu environment için yapılandırma sorunları. Boşsa her şey yolunda.
    public static func problems(in requests: [RequestModel], environment: EnvironmentModel?) -> [Problem] {
        var problems: [Problem] = []
        var owners: [String: [String]] = [:]
        let applicable = requests.filter { ($0.tokenOutput ?? TokenOutput()).applies(to: environment) }
        for request in applicable {
            let output = request.tokenOutput ?? TokenOutput()
            if !isValidVariableName(output.trimmedVariableName) {
                problems.append(.invalidVariableName(request: request.name, name: output.variableName))
            } else {
                owners[output.trimmedVariableName, default: []].append(request.name)
            }
            if output.trimmedResponseField.isEmpty {
                problems.append(.emptyResponseField(request: request.name))
            }
        }
        for (name, names) in owners.sorted(by: { $0.key < $1.key }) where names.count > 1 {
            problems.append(.duplicateVariable(name: name, requests: names))
        }
        let produced = Set(owners.keys)
        for request in applicable {
            let used = SecretReferences.variableNames(in: request, environment: environment)
            for variable in used.intersection(produced).sorted() {
                problems.append(.usesFactoryVariable(request: request.name, variable: variable))
            }
        }
        return problems
    }

    /// `{{isim}}` içinde güvenle kullanılabilecek ad.
    public static func isValidVariableName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("secret:") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
