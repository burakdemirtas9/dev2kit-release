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

    private func perform(_ request: URLRequest, hostPolicy: HostPolicyState) async throws -> OAuth2Token {
        let (data, response) = try await session.data(for: request, delegate: PolicyRedirectGuard(policy: hostPolicy))
        guard let http = response as? HTTPURLResponse else {
            throw OAuth2Client.FlowError(message: L10n.t("oauth.flow.noHTTPResponse"))
        }
        return try OAuth2Client.parseTokenResponse(data, statusCode: http.statusCode)
    }
}

/// Token isteği yönlendirilirse hedef de politikaya uymalı; uymuyorsa
/// yönlendirme izlenmez ve 3xx yanıtı hata olarak döner.
final class PolicyRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let policy: HostPolicyState

    init(policy: HostPolicyState) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(policy.violation(for: request.url) == nil ? request : nil)
    }
}
