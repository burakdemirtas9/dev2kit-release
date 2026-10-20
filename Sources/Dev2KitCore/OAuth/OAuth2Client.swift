import Foundation

/// OAuth2 Authorization Code + PKCE akışı (RFC 6749 + RFC 7636 + RFC 8252).
///
/// URL kurma ve yanıt çözme saf fonksiyonlardır; ağ çağrıları ayrıdır ki
/// güvenlik açısından kritik olan kısım (state doğrulaması, parametreler)
/// ağ olmadan test edilebilsin.
public enum OAuth2Client {
    public struct FlowError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: - Yetkilendirme adresi

    public static func authorizationURL(
        config: OAuth2Config,
        pkce: PKCE,
        state: String,
        redirectURI: String
    ) throws -> URL {
        guard var components = URLComponents(string: config.authorizationURL.trimmingCharacters(in: .whitespaces)),
              components.scheme != nil, components.host != nil else {
            throw FlowError(message: L10n.t("oauth.flow.badAuthURL"))
        }
        guard !config.clientID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FlowError(message: L10n.t("oauth.flow.noClientID"))
        }

        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
        ])
        let scopes = config.scopes.trimmingCharacters(in: .whitespaces)
        if !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes))
        }
        for parameter in config.extraParameters where parameter.enabled && !parameter.key.isEmpty {
            items.append(URLQueryItem(name: parameter.key, value: parameter.value))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw FlowError(message: L10n.t("oauth.flow.buildAuthURL"))
        }
        return url
    }

    // MARK: - Callback çözümleme

    /// Callback adresinden yetkilendirme kodunu çıkarır.
    ///
    /// `state` doğrulaması burada yapılır ve zorunludur: eşleşmezse kod
    /// reddedilir. Bu kontrol olmadan saldırgan kendi kodunu kullanıcıya
    /// kullandırıp hesabını kendi hesabına bağlayabilir (kod enjeksiyonu).
    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw FlowError(message: L10n.t("oauth.flow.badCallback"))
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if let error = value("error") {
            let description = value("error_description") ?? ""
            throw FlowError(message: L10n.t("oauth.flow.denied", description.isEmpty ? error : "\(error) — \(description)"))
        }
        guard let state = value("state") else {
            throw FlowError(message: L10n.t("oauth.flow.noState"))
        }
        // Sabit zamanlı karşılaştırma gerekmez (state gizli değil, tahmin
        // edilemez olması yeterli) ama eşitlik şart.
        guard state == expectedState else {
            throw FlowError(message: L10n.t("oauth.flow.stateMismatch"))
        }
        guard let code = value("code"), !code.isEmpty else {
            throw FlowError(message: L10n.t("oauth.flow.noCode"))
        }
        return code
    }

    // MARK: - Token istekleri

    public static func exchangeRequest(
        config: OAuth2Config,
        code: String,
        verifier: String,
        redirectURI: String,
        resolvedClientSecret: String?
    ) throws -> URLRequest {
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": config.clientID,
            "code_verifier": verifier,
        ]
        if let resolvedClientSecret, !resolvedClientSecret.isEmpty {
            fields["client_secret"] = resolvedClientSecret
        }
        return try tokenRequest(tokenURL: config.tokenURL, fields: fields)
    }

    public static func refreshRequest(
        config: OAuth2Config,
        refreshToken: String,
        resolvedClientSecret: String?
    ) throws -> URLRequest {
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ]
        if let resolvedClientSecret, !resolvedClientSecret.isEmpty {
            fields["client_secret"] = resolvedClientSecret
        }
        let scopes = config.scopes.trimmingCharacters(in: .whitespaces)
        if !scopes.isEmpty { fields["scope"] = scopes }
        return try tokenRequest(tokenURL: config.tokenURL, fields: fields)
    }

    /// Client credentials (RFC 6749 §4.4): kullanıcı yok, uygulama kendi
    /// kimliğiyle token alır. Değerler çağıran tarafından çözülmüş gelir.
    private static func tokenRequest(tokenURL: String, fields: [String: String]) throws -> URLRequest {
        let trimmed = tokenURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw FlowError(message: L10n.t("oauth.flow.badTokenURL"))
        }
        // Token uç noktası kimlik bilgisi taşır; şifresiz kanal kabul edilmez.
        guard url.scheme?.lowercased() == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
            throw FlowError(message: L10n.t("oauth.flow.tokenNotHTTPS"))
        }

        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Dev2KitIdentity.stamp(&request)
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return request
    }

    // MARK: - Yanıt çözümleme

    public static func parseTokenResponse(_ data: Data, statusCode: Int, now: Date = Date()) throws -> OAuth2Token {
        if statusCode >= 400 {
            if let failure = try? JSONDecoder().decode(OAuth2ErrorResponse.self, from: data) {
                let detail = failure.error_description.map { " — \($0)" } ?? ""
                throw FlowError(message: L10n.t("oauth.flow.tokenFailed", "\(failure.error)\(detail)"))
            }
            throw FlowError(message: L10n.t("oauth.flow.tokenFailed", "HTTP \(statusCode)"))
        }
        guard let response = try? JSONDecoder().decode(OAuth2TokenResponse.self, from: data) else {
            throw FlowError(message: L10n.t("oauth.flow.badTokenResponse"))
        }
        return OAuth2Token(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            tokenType: response.token_type ?? "Bearer",
            expiresAt: response.expires_in.map { now.addingTimeInterval($0) },
            scope: response.scope
        )
    }
}
