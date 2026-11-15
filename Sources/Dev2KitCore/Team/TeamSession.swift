import Foundation

/// Kurum oturumu: login, refresh, çıkış ve yetkili istek (rehber §1–§7).
///
/// - Access token yalnızca bellekte; refresh token yalnızca Keychain'de
///   (`refreshTokenStore`; imzasız derlemede `nil` verilir ve yalnızca bellekte
///   tutulur — rehber: dosyada tutma yok). Parola hiçbir yerde tutulmaz.
/// - Refresh token her kullanımda değişir: yanıt gelir gelmez yenisi yazılır.
/// - **Refresh tek seferde (single-flight):** aynı anda birden çok 401 tek
///   refresh'i bekler; iki paralel refresh sunucuda "eski token" sayılıp
///   oturumu düşürürdü.
/// - 401 → bir kez refresh, istek bir kez tekrar. Başarısız login ve 409/403
///   asla otomatik tekrarlanmaz.
/// - Refresh token yalnızca auth servisine gider. Kullanıcının istek motoru ve
///   geçmişi kullanılmaz; hiçbir şey loglanmaz.
public actor TeamSession {
    public static let refreshTokenName = "team.refreshToken"
    /// Access token'ın bitmesine bundan az kaldıysa istekten önce yenilenir.
    static let proactiveRefreshWindow: TimeInterval = 60
    /// Servis yanıtının en büyük boyutu (collection içeriği 5 MB + pay).
    static let maxResponseBytes = 6_000_000

    public let config: TeamConfig
    private let refreshTokenStore: SecretStore?
    private let hostPolicy: @Sendable () -> HostPolicyState
    private let now: @Sendable () -> Date
    private let urlSession: URLSession

    private var accessToken: String?
    private var accessTokenExpiresAt: Date?
    private var refreshTokenInMemory: String?
    public private(set) var identity: TeamIdentity?
    private var refreshTask: Task<TeamIdentity, Error>?

    public init(
        config: TeamConfig = .default,
        refreshTokenStore: SecretStore?,
        hostPolicy: @escaping @Sendable () -> HostPolicyState = { HostPolicyLoader.load() },
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: TimeInterval = 20
    ) {
        self.config = config
        self.refreshTokenStore = refreshTokenStore
        self.hostPolicy = hostPolicy
        self.now = now
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlSession = URLSession(configuration: configuration)
    }

    public var isLoggedIn: Bool { identity != nil }

    /// Açılış: saklı refresh token varsa oturumu sürdürür; yoksa `nil` (login ekranı).
    public func restore() async throws -> TeamIdentity? {
        guard storedRefreshToken() != nil else { return nil }
        return try await refresh()
    }

    // MARK: Login / çıkış

    public func login(username: String, password: String) async throws -> TeamIdentity {
        guard Self.isValidUsername(username) else { throw TeamError.invalidUsername }
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let (data, response) = try await perform(post(config.authBaseURL, "auth/login", body: body))
        switch response.statusCode {
        case 200:
            return try apply(data)
        case 401: throw TeamError.invalidCredentials
        case 403: throw TeamError.passwordChangeRequired
        case 429:
            let seconds = Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw TeamError.tooManyAttempts(retryAfter: max(seconds, 1))
        case 503: throw TeamError.directoryUnavailable
        case 400: throw TeamError.invalidRequest
        default: throw TeamError.http(response.statusCode)
        }
    }

    /// Sonuç ne olursa olsun (ağ hatası dahil) yerel token'lar silinir.
    public func logout() async {
        if let token = storedRefreshToken(),
           let body = try? JSONSerialization.data(withJSONObject: ["refreshToken": token]) {
            _ = try? await perform(post(config.authBaseURL, "auth/logout", body: body))
        }
        clear()
    }

    // MARK: Refresh (single-flight)

    public func refresh() async throws -> TeamIdentity {
        if let running = refreshTask { return try await running.value }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> TeamIdentity {
        guard let token = storedRefreshToken() else {
            clear()
            throw TeamError.sessionExpired
        }
        let body = try JSONSerialization.data(withJSONObject: ["refreshToken": token])
        let (data, response) = try await perform(post(config.authBaseURL, "auth/refresh", body: body))
        switch response.statusCode {
        case 200:
            return try apply(data)
        case 401:
            clear()
            throw TeamError.sessionExpired
        default:
            throw TeamError.http(response.statusCode)
        }
    }

    // MARK: Yetkili istek (dev2kit-data)

    /// Bearer ekler; süre bitmek üzereyse önce yeniler; 401'de bir kez yenileyip
    /// bir kez tekrarlar.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let expiry = accessTokenExpiresAt, expiry.timeIntervalSince(now()) < Self.proactiveRefreshWindow {
            _ = try await refresh()
        }
        guard let token = accessToken else { throw TeamError.notLoggedIn }
        let first = try await perform(authorized(request, token))
        guard first.1.statusCode == 401 else { return first }
        // Arada başka bir istek yenilediyse ikinci refresh yapılmaz.
        if accessToken == token { _ = try await refresh() }
        guard let renewed = accessToken else { throw TeamError.sessionExpired }
        return try await perform(authorized(request, renewed))
    }

    // MARK: Yardımcılar

    static func isValidUsername(_ username: String) -> Bool {
        (1...64).contains(username.count)
            && username.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    private func authorized(_ request: URLRequest, _ token: String) -> URLRequest {
        var copy = request
        copy.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return copy
    }

    private func post(_ base: URL, _ path: String, body: Data) -> URLRequest {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// Login/refresh yanıtını uygular: önce yeni refresh token yazılır (eskisi
    /// artık geçersiz), sonra access token ve kimlik.
    private func apply(_ data: Data) throws -> TeamIdentity {
        struct Response: Decodable {
            struct User: Decodable { let username: String; let displayName: String? }
            let accessToken: String
            let accessTokenExpiresAt: String?
            let refreshToken: String
            let user: User
            let group: String
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.accessToken.isEmpty, !response.refreshToken.isEmpty else {
            throw TeamError.invalidResponse
        }
        storeRefreshToken(response.refreshToken)
        accessToken = response.accessToken
        accessTokenExpiresAt = response.accessTokenExpiresAt.flatMap(TeamDate.parse)
        let identity = TeamIdentity(username: response.user.username, displayName: response.user.displayName, group: response.group)
        self.identity = identity
        return identity
    }

    private func storedRefreshToken() -> String? {
        if let refreshTokenInMemory { return refreshTokenInMemory }
        return (try? refreshTokenStore?.secret(forName: Self.refreshTokenName)) ?? nil
    }

    private func storeRefreshToken(_ token: String) {
        refreshTokenInMemory = token
        do {
            try refreshTokenStore?.setSecret(token, forName: Self.refreshTokenName)
        } catch {
            // Keychain yazılamazsa oturum bellekte sürer; dosyaya düşülmez.
        }
    }

    private func clear() {
        accessToken = nil
        accessTokenExpiresAt = nil
        refreshTokenInMemory = nil
        identity = nil
        try? refreshTokenStore?.deleteSecret(forName: Self.refreshTokenName)
    }

    /// Tek ağ yolu: adres kuralı, host politikası, yönlendirme koruması
    /// (farklı kaynağa gidilmez, Authorization taşınmaz), boyut sınırı.
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, TeamConfig.isAllowed(url) else { throw TeamError.insecureURL }
        var stamped = request
        Dev2KitIdentity.stamp(&stamped)
        let policy = hostPolicy()
        if let violation = policy.violation(for: url) { throw TeamError.blockedByPolicy(violation) }
        let guardian = PolicyRedirectGuard(policy: policy)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: stamped, delegate: guardian)
        } catch {
            throw TeamError.unreachable(error.localizedDescription)
        }
        if let blocked = guardian.blockedDestination {
            throw TeamError.blockedByPolicy(L10n.t("redirect.blockedCredential", blocked.host ?? blocked.absoluteString))
        }
        guard let http = response as? HTTPURLResponse, data.count <= Self.maxResponseBytes else {
            throw TeamError.invalidResponse
        }
        return (data, http)
    }
}
