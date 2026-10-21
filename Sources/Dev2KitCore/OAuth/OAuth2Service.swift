import Foundation

/// OAuth2 akışının ağ tarafı: tarayıcıyı açtırır, callback'i bekler,
/// kodu token'a çevirir, token yeniler.
///
/// Tarayıcı açma işi dışarıdan bir closure ile verilir; çekirdek AppKit'e
/// bağlanmaz. Tarayıcı **sistem tarayıcısıdır**: gömülü bir WebView
/// kullanılmaz, böylece uygulama kullanıcının parolasını hiç görmez.
public struct OAuth2Service: Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    /// Tam yetkilendirme akışı. Dönen token çağıran tarafından vault'a yazılır.
    /// Yetkilendirme ve token adresleri de yönetici politikasına tabidir:
    /// tarayıcı açılmadan ve token isteği gitmeden önce kontrol edilir.
    public func authorize(
        config: OAuth2Config,
        resolvedClientSecret: String?,
        hostPolicy: HostPolicyState,
        openURL: @Sendable (URL) -> Void
    ) async throws -> OAuth2Token {
        try Self.enforce(hostPolicy, on: config.authorizationURL)
        try Self.enforce(hostPolicy, on: config.tokenURL)
        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }

        let pkce = PKCE.generate()
        let state = PKCE.generateState()
        let redirectURI = receiver.redirectURI

        let authorizationURL = try OAuth2Client.authorizationURL(
            config: config,
            pkce: pkce,
            state: state,
            redirectURI: redirectURI
        )
        openURL(authorizationURL)

        let callback = try await receiver.waitForCallback()
        let code = try OAuth2Client.authorizationCode(from: callback, expectedState: state)

        let request = try OAuth2Client.exchangeRequest(
            config: config,
            code: code,
            verifier: pkce.verifier,
            redirectURI: redirectURI,
            resolvedClientSecret: resolvedClientSecret
        )
        return try await perform(request, hostPolicy: hostPolicy)
    }

    public func refresh(
        config: OAuth2Config,
        refreshToken: String,
        resolvedClientSecret: String?,
        hostPolicy: HostPolicyState
    ) async throws -> OAuth2Token {
        try Self.enforce(hostPolicy, on: config.tokenURL)
        let request = try OAuth2Client.refreshRequest(
            config: config,
            refreshToken: refreshToken,
            resolvedClientSecret: resolvedClientSecret
        )
        var token = try await perform(request, hostPolicy: hostPolicy)
        // Bazı sağlayıcılar yenilemede yeni refresh token döndürmez;
        // eskisini koruyoruz, aksi halde bir sonraki yenileme yapılamaz.
        if token.refreshToken == nil {
            token.refreshToken = refreshToken
        }
        return token
    }

    static func enforce(_ policy: HostPolicyState, on address: String) throws {
        let url = URL(string: address.trimmingCharacters(in: .whitespaces))
        if let violation = policy.violation(for: url) {
            throw OAuth2Client.FlowError(message: violation)
        }
    }

    /// Token yanıtının üst sınırı. Gerçek yanıtlar birkaç KB; adres içe
    /// aktarılan koleksiyondan gelebildiği için dev yanıt (ya da açılınca
    /// büyüyen sıkıştırılmış gövde) belleği doldurmasın (güvenlik incelemesi,
    /// 2026-10-21). Sınır açılmış veriye uygulanır.
    static let maxTokenResponseBytes = 1_048_576

    private func perform(_ request: URLRequest, hostPolicy: HostPolicyState) async throws -> OAuth2Token {
        let guardian = PolicyRedirectGuard(policy: hostPolicy)
        let (bytes, response) = try await session.bytes(for: request, delegate: guardian)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxTokenResponseBytes {
                bytes.task.cancel()
                throw OAuth2Client.FlowError(message: L10n.t("oauth.flow.responseTooLarge",
                                                             L10n.number(Self.maxTokenResponseBytes / 1_048_576)))
            }
        }
        if let blocked = guardian.blockedDestination {
            throw OAuth2Client.FlowError(message: L10n.t("oauth.flow.redirectBlocked", blocked.host ?? blocked.absoluteString))
        }
        guard let http = response as? HTTPURLResponse else {
            throw OAuth2Client.FlowError(message: L10n.t("oauth.flow.noHTTPResponse"))
        }
        return try OAuth2Client.parseTokenResponse(data, statusCode: http.statusCode)
    }
}

/// Kimlik bilgisi taşıyan isteğin (OAuth token alışverişi/yenileme, Postman
/// API) yönlendirmesi. Yalnızca AYNI kaynağa, https → http düşüşü olmadan ve
/// yönetici politikasına uyarak izlenir; aksi halde izlenmez ve çağıran açık
/// bir hata verir.
///
/// Neden: 307/308 yönlendirme POST gövdesini (client_secret, refresh_token)
/// ve başlıkları (X-Api-Key) olduğu gibi yeni hedefe taşır. Önceden yalnızca
/// host politikası kontrol ediliyordu; politika yoksa başka bir kaynağa
/// gidiyordu (güvenlik incelemesi F3, 2026-10-20).
final class PolicyRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: HostPolicyState
    private let lock = NSLock()
    private var blocked: URL?

    init(policy: HostPolicyState) {
        self.policy = policy
    }

    /// İzlenmeyen yönlendirmenin hedefi (yoksa `nil`).
    var blockedDestination: URL? {
        lock.lock(); defer { lock.unlock() }
        return blocked
    }

    /// Yönlendirme izlenebilir mi: aynı kaynak, düşüş yok, politikaya uygun.
    static func allows(from source: URL?, to destination: URL?, policy: HostPolicyState) -> Bool {
        guard let source, let destination else { return false }
        return !RedirectGuard.isCrossOrigin(source, destination) && policy.violation(for: destination) == nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Aynı kaynak şemayı da kapsar: https → http farklı kaynaktır.
        let source = task.originalRequest?.url ?? response.url
        if Self.allows(from: source, to: request.url, policy: policy) {
            completionHandler(request)
        } else {
            lock.lock(); blocked = request.url; lock.unlock()
            completionHandler(nil)
        }
    }
}
