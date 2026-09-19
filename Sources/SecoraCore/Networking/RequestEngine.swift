import Foundation
import Security

/// Gönderilmiş bir isteğin sonucu. Body ham byte olarak tutulur;
/// metin/JSON yorumlama UI katmanına bırakılır.
public struct ResponseData: Sendable {
    public let statusCode: Int
    public let headers: [(name: String, value: String)]
    public let body: Data
    public let duration: TimeInterval
    public let finalURL: URL?
    /// İzlenen yönlendirme zinciri (denetim izi).
    public let redirects: [RedirectStep]
    /// Zincir bir politika nedeniyle kesildiyse sebebi.
    public let redirectStop: RedirectGuard.Decision.StopReason?

    public init(
        statusCode: Int,
        headers: [(name: String, value: String)],
        body: Data,
        duration: TimeInterval,
        finalURL: URL?,
        redirects: [RedirectStep] = [],
        redirectStop: RedirectGuard.Decision.StopReason? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.duration = duration
        self.finalURL = finalURL
        self.redirects = redirects
        self.redirectStop = redirectStop
    }

    public var bodyText: String? { String(data: body, encoding: .utf8) }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

public enum RequestEngineError: Error, LocalizedError {
    case invalidURL(String)
    case notHTTPResponse
    case notAuthorized(String)
    /// Kesin güvenlik engeli: istek gönderilmedi, kullanıcı geçersiz kılamaz.
    case securityBlocked([SecurityFinding])
    /// Onay bekleyen güvenlik uyarıları: istek gönderilmedi.
    case needsApproval([SecurityFinding])

    public var errorDescription: String? {
        switch self {
        case .securityBlocked(let findings), .needsApproval(let findings):
            return findings.map { "\($0.title): \($0.detail)" }.joined(separator: "\n")
        case .invalidURL(let url): return "Geçersiz URL: \(url)"
        case .notHTTPResponse: return "Sunucudan HTTP yanıtı alınamadı."
        case .notAuthorized(let name):
            return "\"\(name)\" için henüz token yok. Auth sekmesinden \"Yetkilendir\" ile giriş yap."
        }
    }
}

/// URLSession tabanlı istek motoru.
/// Şablon çözümü (değişken + secret) gönderim anında yapılır; çözülmüş
/// değerler bu fonksiyonun dışına sızmaz ve loglanmaz.
public final class RequestEngine: @unchecked Sendable {
    /// Çerez kavanozu kapsamı. Her environment kendi izole oturumunu alır:
    /// Dev ortamında alınan oturum çerezi Prod isteğine taşınamaz.
    public struct Scope: Hashable, Sendable {
        let key: String
        public init(environmentID: UUID?) {
            self.key = environmentID?.uuidString ?? "default"
        }
    }

    private let lock = NSLock()
    private var sessions: [Scope: URLSession] = [:]

    public init() {}

    /// Kapsamın oturumu. `ephemeral` yapılandırma çerezleri YALNIZCA bellekte
    /// tutar; oturum kimlik bilgileri diske hiç yazılmaz, uygulama kapanınca gider.
    private func session(for scope: Scope) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let existing = sessions[scope] { return existing }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.urlCache = nil
        let session = URLSession(configuration: config)
        sessions[scope] = session
        return session
    }

    /// Kapsamdaki çerezleri listeler (denetim ekranı için).
    public func cookies(in scope: Scope) -> [HTTPCookie] {
        session(for: scope).configuration.httpCookieStorage?.cookies ?? []
    }

    /// Kapsamdaki tüm çerezleri siler ("oturumu kapat").
    public func clearCookies(in scope: Scope) {
        guard let storage = session(for: scope).configuration.httpCookieStorage else { return }
        storage.cookies?.forEach(storage.deleteCookie)
    }

    /// Host bazlı TLS profilleri. Gönderimden önce çözülür ki dosya/parola
    /// hataları anlaşılır mesajla dönsün, TLS el sıkışma hatası olarak değil.
    public var tlsProfiles: [TLSProfile] = []
    /// Kurum güven deposundaki CA'lar (cacerts dizini). Her istekte dosya
    /// okumamak için burada tutulur; değişince AppState yeniler.
    public var trustStoreCertificates: [SecCertificate] = []

    /// - Parameters:
    ///   - hostPolicy: Yönetici host politikası. Bilerek varsayılan değersiz:
    ///     her çağıran politikayı açıkça vermek zorunda, unutulup atlanamasın.
    ///   - approvedWarnings: Kullanıcının daha önce onayladığı uyarı anahtarları.
    public func send(
        _ model: RequestModel,
        environment: EnvironmentModel?,
        secretStore: SecretStore,
        hostPolicy: HostPolicyState,
        approvedWarnings: Set<String> = []
    ) async throws -> ResponseData {
        let resolver = VariableResolver(environment: environment, secretStore: secretStore)
        var urlRequest = try buildURLRequest(model, resolver: resolver)

        // Ağa çıkmadan önce: engel varsa hiç gönderilmez, onaylanmamış uyarı
        // varsa kullanıcıya sorulmak üzere durulur.
        let findings = RequestInspector.inspect(
            model: model,
            request: urlRequest,
            environment: environment,
            policy: hostPolicy
        )
        try RequestInspector.enforce(findings, approved: approvedWarnings)

        urlRequest.timeoutInterval = model.options.timeout
        // Çerez gönderimi istek başına kapatılabilir.
        urlRequest.httpShouldHandleCookies = model.options.sendCookies

        let scope = Scope(environmentID: environment?.id)
        let tlsProfile = try resolveTLSProfile(for: urlRequest.url, resolver: resolver)
        let tracker = RedirectTracker(
            policy: model.options.redirect,
            credentialHeaders: RedirectGuard.credentialHeaders(for: model),
            hostPolicy: hostPolicy,
            tlsProfile: tlsProfile
        )
        let start = ContinuousClock.now
        let (data, response) = try await session(for: scope).data(for: urlRequest, delegate: tracker)
        let elapsed = start.duration(to: .now)

        guard let http = response as? HTTPURLResponse else {
            throw RequestEngineError.notHTTPResponse
        }
        let headers: [(String, String)] = http.allHeaderFields.compactMap { key, value in
            guard let name = key as? String else { return nil }
            return (name, "\(value)")
        }.sorted { $0.0.lowercased() < $1.0.lowercased() }

        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return ResponseData(
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            duration: seconds,
            finalURL: http.url,
            redirects: tracker.steps,
            redirectStop: tracker.stopReason
        )
    }

    // İç kurgu ayrı fonksiyonda: URL/header/auth üretimi network'süz test edilebilsin.
    func buildURLRequest(_ model: RequestModel, resolver: VariableResolver) throws -> URLRequest {
        let resolvedURLString = try resolver.resolve(model.url.trimmingCharacters(in: .whitespaces))
        guard var components = URLComponents(string: resolvedURLString),
              components.scheme != nil, components.host != nil else {
            throw RequestEngineError.invalidURL(resolvedURLString)
        }

        var queryItems = components.queryItems ?? []
        for entry in model.queryParams where entry.enabled && !entry.key.isEmpty {
            queryItems.append(URLQueryItem(
                name: try resolver.resolve(entry.key),
                value: try resolver.resolve(entry.value)
            ))
        }
        // Auth query param'a eklenecekse burada işlenir.
        if case .apiKey(let key, let value, .queryParam) = model.auth {
            queryItems.append(URLQueryItem(
                name: try resolver.resolve(key),
                value: try resolver.resolve(value)
            ))
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }

        guard let url = components.url else {
            throw RequestEngineError.invalidURL(resolvedURLString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = model.method.rawValue

        for entry in model.headers where entry.enabled && !entry.key.isEmpty {
            try setHeader(try resolver.resolve(entry.value), named: try resolver.resolve(entry.key), on: &request)
        }

        switch model.auth {
        case .none, .apiKey(_, _, .queryParam):
            break
        case .basic(let username, let password):
            let credentials = "\(try resolver.resolve(username)):\(try resolver.resolve(password))"
            let encoded = Data(credentials.utf8).base64EncodedString()
            try setHeader("Basic \(encoded)", named: "Authorization", on: &request)
        case .bearer(let token):
            try setHeader("Bearer \(try resolver.resolve(token))", named: "Authorization", on: &request)
        case .apiKey(let key, let value, .header):
            try setHeader(try resolver.resolve(value), named: try resolver.resolve(key), on: &request)
        case .oauth2(let config):
            guard let stored = try resolver.secret(named: config.tokenSecretName), !stored.isEmpty else {
                throw RequestEngineError.notAuthorized(config.name)
            }
            if let data = stored.data(using: .utf8),
               let token = try? JSONDecoder().decode(OAuth2Token.self, from: data) {
                try setHeader(token.authorizationHeaderValue, named: "Authorization", on: &request)
            } else {
                // cURL dışa aktarımında vault yerine placeholder gelir; aynen geçir.
                try setHeader("Bearer \(stored)", named: "Authorization", on: &request)
            }
        }

        try attachBody(to: &request, model: model, resolver: resolver)
        return request
    }

    /// Foundation satır sonu (CR/LF) içeren başlığı SESSİZCE düşürür: istek
    /// kimlik bilgisi olmadan gider ve kullanıcı nedenini göremez. Değer
    /// (secret ya da değişkenden gelmiş olabilir) burada çözülmüş haliyle
    /// denetlenir ve açık bir güvenlik engeli olarak durdurulur.
    private func setHeader(_ value: String, named name: String, on request: inout URLRequest) throws {
        if RequestInspector.containsHiddenCharacters(name, allowTab: false)
            || RequestInspector.containsHiddenCharacters(value, allowTab: true) {
            throw RequestEngineError.securityBlocked([RequestInspector.headerInjectionFinding(name)])
        }
        request.setValue(value, forHTTPHeaderField: name)
    }

    private func attachBody(
        to request: inout URLRequest,
        model: RequestModel,
        resolver: VariableResolver
    ) throws {
        switch model.body {
        case .none:
            return

        case .raw(let content, let contentType):
            let data = Data(try resolver.resolve(content).utf8)
            guard !data.isEmpty else { return }
            setBody(data, contentType: contentType.isEmpty ? nil : contentType,
                    on: &request, method: model.method)

        case .formURLEncoded(let fields):
            var components = URLComponents()
            components.queryItems = try fields
                .filter { $0.enabled && !$0.key.isEmpty }
                .map { URLQueryItem(name: try resolver.resolve($0.key), value: try resolver.resolve($0.value)) }
            guard let query = components.percentEncodedQuery, !query.isEmpty else { return }
            setBody(Data(query.utf8), contentType: "application/x-www-form-urlencoded",
                    on: &request, method: model.method)

        case .multipartForm(let fields):
            let activeFields = fields.filter { $0.enabled && !$0.key.isEmpty }
            guard !activeFields.isEmpty else { return }
            let boundary = "secora-\(UUID().uuidString)"
            var data = Data()
            for field in activeFields {
                // Alan adındaki tırnak/backslash, Content-Disposition'ı bozmasın.
                let name = try resolver.resolve(field.key)
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                data.append(Data("--\(boundary)\r\n".utf8))
                data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
                data.append(Data("\(try resolver.resolve(field.value))\r\n".utf8))
            }
            data.append(Data("--\(boundary)--\r\n".utf8))
            setBody(data, contentType: "multipart/form-data; boundary=\(boundary)",
                    on: &request, method: model.method)
        }
    }

    /// Host'a uyan profili bulup sertifikalarını yükler.
    private func resolveTLSProfile(
        for url: URL?,
        resolver: VariableResolver
    ) throws -> ResolvedTLSProfile? {
        guard let host = url?.host else { return nil }
        let profile = TLSProfile.profile(for: host, in: tlsProfiles)

        var certificates: [SecCertificate] = []
        var identity: SecIdentity?
        let pin = profile?.pinToCA ?? false

        if let profile {
            if profile.hasCA {
                certificates = try CertificateLoader.loadCertificates(atPath: profile.caCertificatePath)
            }
            if profile.hasClientCertificate {
                let password = try resolver.resolve(profile.clientCertificatePassword)
                identity = try CertificateLoader.loadIdentity(
                    atPath: profile.clientCertificatePath,
                    password: password
                )
            }
        }

        // Kurum güven deposu TÜM host'lara ek çıpa olarak uygulanır.
        // Sabitleme açıkken dahil edilmez: sabitleme, sabitleme demektir —
        // yoksa depoya bırakılan herhangi bir CA sabitlemeyi delerdi.
        if !pin {
            certificates.append(contentsOf: trustStoreCertificates)
        }

        let resolved = ResolvedTLSProfile(
            caCertificates: certificates,
            pinToCA: pin,
            identity: identity
        )
        return resolved.isEmpty ? nil : resolved
    }

    private func setBody(
        _ data: Data,
        contentType: String?,
        on request: inout URLRequest,
        method: HTTPMethod
    ) {
        switch method {
        case .get, .head, .options:
            // URLSession bu metotlarda httpBody'yi sessizce düşürür;
            // body'nin gerçekten gönderilmesi için stream kullanılır.
            request.httpBodyStream = InputStream(data: data)
            request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        default:
            request.httpBody = data
        }
        // Headers sekmesinde elle girilen Content-Type her zaman kazanır.
        if request.value(forHTTPHeaderField: "Content-Type") == nil, let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
    }
}
