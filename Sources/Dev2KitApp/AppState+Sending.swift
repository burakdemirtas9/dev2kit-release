import AppKit
import Foundation
import SwiftUI
import Dev2KitCore

/// Gönderim akışı: istek gönderme, yanıt durumu, güvenlik onayları, iptal;
/// ayrıca gönderimden önce hazırlanması gereken Token Factory token'ları
/// (bkz. AppState+TokenFactory) ve OAuth2.
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
        // Önceki denemeden kalan öneri yeni istekle karışmasın.
        tlsSuggestion = nil
        let environment = activeEnvironment
        // Token Factory isteğinin kendisi token değişkenlerine bağlanmaz (o
        // token'ı ÜRETEN istek); diğer istekler kullandıkları token'ları alır.
        let isTokenRequest = isTokenFactoryRequest(id)
        let usedTokens = isTokenRequest
            ? []
            : TokenFactory.referenced(by: request, environment: environment, sources: tokenSources(for: environment))

        inFlight[id] = Task { [weak self] in
            guard let self else { return }
            do {
                await self.ensureValidToken(request)
                // Token kullanan istekte önce geçerli token hazırlanır; süresinin
                // bitmesine 10 sn'den fazla varsa bellektekiyle hiç ağa
                // çıkılmadan devam edilir. Alınamazsa istek GÖNDERİLMEZ.
                let sendEnvironment: EnvironmentModel?
                let sendStore: SecretStore
                do {
                    (sendEnvironment, sendStore) = try await self.prepareTokens(usedTokens, environment: environment)
                } catch let error as TokenError {
                    self.showTokenAlert(error.localizedDescription, for: id)
                    throw error
                }
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
                if response.statusCode == 401 {
                    usedTokens.forEach { self.forgetToken($0, environment: environment) }
                }
                if isTokenRequest {
                    self.absorbTokenResponse(request, response: response, environment: environment)
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
                // TLS güven hatasıysa: host'a uyan profil yok ama benzeri
                // varsa kullanıcıya eklemeyi teklif et.
                self.offerTLSSuggestion(for: error)
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
