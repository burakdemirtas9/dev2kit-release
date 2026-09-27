import AppKit
import Foundation
import SwiftUI
import Dev2KitCore

/// Gönderim akışı: istek gönderme, yanıt durumu, güvenlik onayları, iptal;
/// ayrıca gönderimden önce hazırlanması gereken token değişkenleri ve OAuth2.
/// Hepsi tek zincir olduğu için aynı dosyada: gönder → (gerekirse) token al →
/// (gerekirse) onay iste → yanıtı yaz → geçmişe kaydet.

extension AppState {
    private func setResponse(_ state: ResponseState, for id: UUID) {
        responses[id] = state
        responseOrder.removeAll { $0 == id }
        responseOrder.append(id)
        while responseOrder.count > Self.retainedResponseLimit {
            responses.removeValue(forKey: responseOrder.removeFirst())
        }
    }

    func send(_ request: RequestModel) {
        flushPendingWrites()
        // Gönderilen istek kullanılan istektir: önizleme sekmesi kalıcı olur.
        pinTab(request.id)
        let id = request.id
        // Aynı isteğin önceki gönderimi hâlâ uçuyorsa iptal et.
        inFlight[id]?.cancel()
        setResponse(.loading, for: id)
        let environment = activeEnvironment
        let usedTokens = TokenVariables.referenced(by: request, environment: environment)

        inFlight[id] = Task { [weak self] in
            guard let self else { return }
            do {
                await self.ensureValidToken(request)
                // Token değişkeni kullanan istekte önce geçerli token hazırlanır;
                // süresi dolmamışsa bellektekiyle hiç ağa çıkılmadan devam edilir.
                let (sendEnvironment, sendStore) = try await self.prepareTokens(usedTokens, environment: environment)
                let response = try await engine.send(
                    request,
                    environment: sendEnvironment,
                    secretStore: sendStore,
                    hostPolicy: self.hostPolicy,
                    approvedWarnings: self.approvalStore.load()
                )
                // Token sunucuda erken geçersiz kılınmış olabilir: bir sonraki
                // gönderim yenisini alsın. İstek bilerek yeniden gönderilmez;
                // kullanıcı 401'i görür ve tekrar gönderir.
                if response.statusCode == 401, let environment {
                    usedTokens.forEach { self.forgetToken($0, in: environment) }
                }
                let display = await Task.detached { AppState.makeDisplay(response) }.value
                try Task.checkCancellation()
                self.setResponse(.success(display), for: id)
                // Referans noktası: "en son bunu test ettim".
                self.recordBaseline(request)
                let data = display.data
                self.recordHistory(
                    request,
                    outcome: .completed(
                        status: data.statusCode,
                        duration: data.duration,
                        byteCount: data.body.count,
                        redirectCount: data.redirects.count
                    ),
                    responseText: display.prettyText
                )
            } catch is CancellationError {
                self.setResponse(.idle, for: id)
            } catch let error as URLError where error.code == .cancelled {
                self.setResponse(.idle, for: id)
            } catch RequestEngineError.securityBlocked(let findings) {
                self.setResponse(.blocked(findings), for: id)
                // Denetim izi: engellenen gönderim geçmişte görünsün.
                let reasons = findings.map(\.title).joined(separator: ", ")
                self.recordHistory(request, outcome: .failed(message: "Güvenlik engeli: \(reasons)"), responseText: nil)
            } catch RequestEngineError.needsApproval(let findings) {
                self.setResponse(.needsApproval(findings), for: id)
            } catch {
                self.setResponse(.failure(error.localizedDescription), for: id)
                self.recordHistory(request, outcome: .failed(message: error.localizedDescription), responseText: nil)
            }
            self.inFlight[id] = nil
        }
    }

    /// Kullanıcı uyarıları gördü ve "Yine de gönder" dedi: onaylar kalıcı
    /// kaydedilir, seçili isteğin GÜNCEL hali yeniden gönderilir. İstek bu
    /// arada değiştiyse yeni durum yeniden denetlenir; onay yalnızca
    /// gösterilen uyarıları kapsar.
    func approveAndSend(_ findings: [SecurityFinding]) {
        guard let request = selectedRequest?.wrappedValue else { return }
        do {
            try approvalStore.approve(findings.compactMap(\.approvalKey))
        } catch {
            setResponse(.failure("Onay kaydedilemedi: \(error.localizedDescription)"), for: request.id)
            return
        }
        send(request)
    }

    func dismissSecurityReview() {
        guard let id = selectedRequestID else { return }
        setResponse(.idle, for: id)
    }

    /// Tüm "Yine de gönder" onaylarını unutur; uyarılar yeniden sorulur.
    func resetSecurityApprovals() throws {
        try approvalStore.reset()
    }

    /// Uçuştaki isteği iptal eder. Bağlantı kapanır, kimlik bilgisi taşıyan
    /// istek yarıda kalmaz.
    func cancelSend(_ id: UUID) {
        inFlight[id]?.cancel()
        inFlight[id] = nil
        setResponse(.idle, for: id)
    }

    /// Anahtar değişkenin ayarlarını da içerir: token adresi, client ya da
    /// scope değişince eski token (süresi dolmamış olsa bile) kullanılmaz.
    func tokenKey(_ variable: TokenVariable, in environment: EnvironmentModel) -> String {
        "\(environment.id.uuidString)/\(variable.id.uuidString)/\(variable.hashValue)"
    }

    func tokenState(_ variable: TokenVariable, in environment: EnvironmentModel) -> TokenState? {
        tokenStates[tokenKey(variable, in: environment)]
    }

    /// Gönderim için environment ve secret deposunu hazırlar: kullanılan her
    /// token değişkeni geçerli bir token'a bağlanır.
    private func prepareTokens(
        _ variables: [TokenVariable],
        environment: EnvironmentModel?
    ) async throws -> (EnvironmentModel?, SecretStore) {
        guard let environment, !variables.isEmpty else { return (environment, secretStore) }
        var overrides: [String: String] = [:]
        for variable in variables {
            overrides[variable.secretName] = try await validToken(variable, in: environment).accessToken
        }
        return (TokenVariables.environmentForSend(environment), OverlaySecretStore(base: secretStore, overrides: overrides))
    }

    /// Bellekteki token geçerliyse onu, değilse yenisini döner.
    func validToken(_ variable: TokenVariable, in environment: EnvironmentModel, forceRefresh: Bool = false) async throws -> OAuth2Token {
        let key = tokenKey(variable, in: environment)
        if !forceRefresh, let cached = tokenCache[key], !cached.isExpired() { return cached }
        if let running = tokenFetches[key] {
            do {
                return try await running.value
            } catch {
                throw TokenError(variable: variable.trimmedName, reason: error.localizedDescription)
            }
        }

        let resolver = VariableResolver(environment: environment, secretStore: secretStore)
        let service = oauthService
        let policy = hostPolicy
        let task = Task { () throws -> OAuth2Token in
            try await service.clientCredentials(
                tokenURL: try resolver.resolve(variable.tokenURL),
                clientID: try resolver.resolve(variable.clientID),
                clientSecret: try resolver.resolve(variable.clientSecret),
                scope: try resolver.resolve(variable.scope),
                authentication: variable.clientAuthentication,
                hostPolicy: policy
            )
        }
        tokenFetches[key] = task
        tokenStates[key] = .fetching
        defer { tokenFetches[key] = nil }
        do {
            let token = try await task.value
            tokenCache[key] = token
            tokenStates[key] = .valid(expiresAt: token.expiresAt)
            return token
        } catch {
            tokenCache[key] = nil
            tokenStates[key] = .failed(error.localizedDescription)
            throw TokenError(variable: variable.trimmedName, reason: error.localizedDescription)
        }
    }

    func forgetToken(_ variable: TokenVariable, in environment: EnvironmentModel) {
        let key = tokenKey(variable, in: environment)
        tokenCache[key] = nil
        tokenStates[key] = nil
    }

    /// Gönderimden önce token'ın geçerli olduğundan emin olur; süresi dolmuşsa
    /// refresh token ile sessizce yeniler.
    private func ensureValidToken(_ request: RequestModel) async {
        guard case .oauth2(let config) = request.auth,
              let token = storedToken(for: config),
              token.isExpired(),
              let refreshToken = token.refreshToken else { return }
        do {
            let renewed = try await oauthService.refresh(
                config: config,
                refreshToken: refreshToken,
                resolvedClientSecret: resolvedClientSecret(config),
                hostPolicy: hostPolicy
            )
            try saveToken(renewed, for: config)
        } catch {
            // Yenileme başarısızsa istek eski token'la gider ve 401 alır;
            // kullanıcı Auth sekmesinden yeniden yetkilendirir.
            authMessage = "Token yenilenemedi: \(error.localizedDescription)"
        }
    }

    func storedToken(for config: OAuth2Config) -> OAuth2Token? {
        guard let raw = try? secretStore.secret(forName: config.tokenSecretName),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuth2Token.self, from: data)
    }

    /// Client secret `{{secret:isim}}` ile verilmiş olabilir; çözülür.
    private func resolvedClientSecret(_ config: OAuth2Config) -> String? {
        let raw = config.clientSecret.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let resolver = VariableResolver(environment: activeEnvironment, secretStore: secretStore)
        return (try? resolver.resolve(raw)) ?? raw
    }

    /// Tarayıcıyı açıp yetkilendirme akışını yürütür.
    func authorize(_ config: OAuth2Config) {
        authorizingConfigID = config.id
        authMessage = nil
        Task {
            do {
                let token = try await oauthService.authorize(
                    config: config,
                    resolvedClientSecret: resolvedClientSecret(config),
                    hostPolicy: hostPolicy,
                    openURL: { url in NSWorkspace.shared.open(url) }
                )
                try saveToken(token, for: config)
                authMessage = "Yetkilendirme tamamlandı."
            } catch {
                authMessage = error.localizedDescription
            }
            authorizingConfigID = nil
        }
    }
}
