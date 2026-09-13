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
    public func authorize(
        config: OAuth2Config,
        resolvedClientSecret: String?,
        openURL: @Sendable (URL) -> Void
    ) async throws -> OAuth2Token {
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
        return try await perform(request)
    }

    public func refresh(
        config: OAuth2Config,
        refreshToken: String,
        resolvedClientSecret: String?
    ) async throws -> OAuth2Token {
        let request = try OAuth2Client.refreshRequest(
            config: config,
            refreshToken: refreshToken,
            resolvedClientSecret: resolvedClientSecret
        )
        var token = try await perform(request)
        // Bazı sağlayıcılar yenilemede yeni refresh token döndürmez;
        // eskisini koruyoruz, aksi halde bir sonraki yenileme yapılamaz.
        if token.refreshToken == nil {
            token.refreshToken = refreshToken
        }
        return token
    }

    private func perform(_ request: URLRequest) async throws -> OAuth2Token {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuth2Client.FlowError(message: "Sağlayıcıdan HTTP yanıtı alınamadı.")
        }
        return try OAuth2Client.parseTokenResponse(data, statusCode: http.statusCode)
    }
}
