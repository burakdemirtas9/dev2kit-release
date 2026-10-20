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

    /// - Parameter refreshingTokens: kullanıcı "token'ı yenile ve tekrar
    ///   gönder" dedi: kullanılan token'lar bellekte geçerli görünse de
    ///   yeniden alınır ve sonuç buna göre yorumlanır (bkz. `TokenRetryAdvice`).
    /// - Parameter skippingTokens: token alınamadı ve kullanıcı "yine de
    ///   gönder" dedi: Token Factory'ye gidilmez, değişken environment'taki
    ///   aynı adlı değere ya da boşa bağlanır (`environmentWithoutTokens`).
    func send(_ request: RequestModel, refreshingTokens: Bool = false, skippingTokens: Bool = false) {
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
        tokenRetryAdvice[id] = nil
        tokenBlockedSends[id] = nil

        inFlight[id] = Task { [weak self] in
            guard let self else { return }
            do {
                await self.ensureValidToken(request)
                // Token kullanan istekte önce geçerli token hazırlanır; süresinin
                // bitmesine 10 sn'den fazla varsa bellektekiyle hiç ağa
                // çıkılmadan devam edilir. Alınamazsa istek GÖNDERİLMEZ.
                let sendEnvironment: EnvironmentModel?
                let sendStore: SecretStore
                if skippingTokens {
                    (sendEnvironment, sendStore) = (
                        TokenFactory.environmentWithoutTokens(environment, sources: usedTokens),
                        self.secretStore
                    )
                } else {
                    do {
                        (sendEnvironment, sendStore) = try await self.prepareTokens(
                            usedTokens,
                            environment: environment,
                            forceRefresh: refreshingTokens
                        )
                    } catch let error as TokenError {
                        self.tokenBlockedSends[id] = usedTokens.map(\.variable)
                        self.showTokenAlert(L10n.t("token.alert.notSent"), error.localizedDescription, for: id)
                        throw error
                    }
                }
                let response = try await engine.send(
                    request,
                    environment: sendEnvironment,
                    secretStore: sendStore,
                    hostPolicy: self.hostPolicy,
                    approvedWarnings: self.approvalStore.load()
                )
                // Token kullanan istek hata aldıysa yenileme KULLANICIYA önerilir
                // (TokenRetryAdvice); token sessizce düşürülmez, istek
                // kendiliğinden yeniden gönderilmez — POST iki kez çalışmasın.
                if isTokenRequest {
                    self.absorbTokenResponse(request, response: response, environment: environment)
                }
                self.tokenRetryAdvice[id] = TokenRetryAdvice.advice(
                    statusCode: response.statusCode,
                    usedVariables: usedTokens.map(\.variable),
                    afterRefresh: refreshingTokens
                )
                // Büyük yığın: sunucudan gelen derin gövde yığını taşırmasın (BackgroundWork).
                let display = await BackgroundWork.run { AppState.makeDisplay(response) }
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
                self.recordHistory(request, outcome: .failed(message: L10n.t("send.blocked.history", reasons)), responseText: nil)
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
            setResponse(.failure(L10n.t("send.approvalFailed", error.localizedDescription)), for: request.id)
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
            authMessage = (L10n.t("oauth.refreshFailed", error.localizedDescription), false)
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
                authMessage = (L10n.t("oauth.authorized"), true)
            } catch {
                authMessage = (error.localizedDescription, false)
            }
            authorizingConfigID = nil
        }
    }
}

// MARK: - Yanıt durumu ve OAuth2 token kaydı

extension AppState {
    enum ResponseState {
        case idle
        case loading
        case success(ResponseDisplay)
        case failure(String)
        /// Kesin güvenlik engeli; istek gönderilmedi.
        case blocked([SecurityFinding])
        /// Güvenlik uyarıları; istek gönderilmedi, kullanıcının kararı bekleniyor.
        case needsApproval([SecurityFinding])
    }

    /// Yanıtın gösterime hazır hali. Pretty-print ve dil tespiti yanıt gelince
    /// BİR KEZ, arka planda yapılır; her render'da yeniden JSON parse etmek
    /// büyük yanıtlarda paneli kilitliyordu.
    struct ResponseDisplay: Sendable {
        let data: ResponseData
        let prettyText: String
        let language: CodeLanguage
        /// Önizlenebiliyorsa türü. Gövdenin ilk byte'larına bakmak her
        /// render'da yapılacak iş değil; tür tespitiyle birlikte bir kez.
        let previewKind: ResponsePreview.Kind?
        /// Editörde gösterilebilir mi (`WorkbenchLimits`, Workbench çıktısıyla
        /// aynı kural: 20 MB'a kadar, 1 MB'tan uzun satır yok). Biçimlenemeyen
        /// tek satırlık büyük yanıt (düz metin, bozuk JSON) editörü
        /// donduruyordu; o durumda yalnızca kopyalanır. Bir kez, burada.
        var fitsEditor = true
        /// Gövdenin boyutu/satırı/karakteri (alt bilgi). Büyük yanıtta her
        /// çizimde sayılmasın diye burada, arka planda bir kez.
        var stats: TextStats = .empty
    }

    /// Ana thread dışında çalışır: büyük gövdeleri biçimlendirmek pahalıdır.
    nonisolated static func makeDisplay(_ response: ResponseData) -> ResponseDisplay {
        let contentType = response.headers
            .first { $0.name.lowercased() == "content-type" }?.value ?? ""
        let text = response.bodyText ?? L10n.plural("response.binary", count: response.body.count)
        // Tür tahmini ve biçimlendirme tek yerde: Beautifier (Core, testli).
        let kind = Beautifier.kind(contentType: contentType, body: text)
        let pretty = Beautifier.beautifiedOrOriginal(text, as: kind)
        return ResponseDisplay(
            data: response,
            prettyText: pretty,
            language: CodeLanguage(kind),
            previewKind: ResponsePreview.kind(contentType: contentType, body: response.body),
            fitsEditor: !WorkbenchLimits.isTooLargeForEditor(pretty, maxBytes: WorkbenchLimits.maxOutputBytes),
            stats: TextStats(pretty)
        )
    }

    /// Token'ı vault'a yazar. Adı `store` DEĞİL: `store` aynı zamanda
    /// workspace deposunun adı, uzantı dosyalarında çağrı karışıyordu.
    func saveToken(_ token: OAuth2Token, for config: OAuth2Config) throws {
        let data = try JSONEncoder().encode(token)
        // Token vault'a yazılır; workspace dosyasına ASLA.
        try secretStore.setSecret(String(decoding: data, as: UTF8.self), forName: config.tokenSecretName)
        invalidateSecretNames()
    }

    func clearToken(for config: OAuth2Config) {
        try? secretStore.deleteSecret(forName: config.tokenSecretName)
        invalidateSecretNames()
        authMessage = (L10n.t("oauth.tokenDeleted"), true)
    }
}
