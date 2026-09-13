import Foundation

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

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Geçersiz URL: \(url)"
        case .notHTTPResponse: return "Sunucudan HTTP yanıtı alınamadı."
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

    public func send(
        _ model: RequestModel,
        environment: EnvironmentModel?,
        secretStore: SecretStore
    ) async throws -> ResponseData {
        let resolver = VariableResolver(environment: environment, secretStore: secretStore)
        var urlRequest = try buildURLRequest(model, resolver: resolver)
        urlRequest.timeoutInterval = model.options.timeout
        // Çerez gönderimi istek başına kapatılabilir.
        urlRequest.httpShouldHandleCookies = model.options.sendCookies

        let scope = Scope(environmentID: environment?.id)
        let tracker = RedirectTracker(
            policy: model.options.redirect,
            credentialHeaders: RedirectGuard.credentialHeaders(for: model)
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
            request.setValue(
                try resolver.resolve(entry.value),
                forHTTPHeaderField: try resolver.resolve(entry.key)
            )
        }

        switch model.auth {
        case .none, .apiKey(_, _, .queryParam):
            break
        case .basic(let username, let password):
            let credentials = "\(try resolver.resolve(username)):\(try resolver.resolve(password))"
            let encoded = Data(credentials.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        case .bearer(let token):
            request.setValue("Bearer \(try resolver.resolve(token))", forHTTPHeaderField: "Authorization")
        case .apiKey(let key, let value, .header):
            request.setValue(try resolver.resolve(value), forHTTPHeaderField: try resolver.resolve(key))
        }

        try attachBody(to: &request, model: model, resolver: resolver)
        return request
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
            let boundary = "boltdock-\(UUID().uuidString)"
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
