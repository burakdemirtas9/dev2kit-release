import Foundation
import Dev2KitCore

/// Token Factory: token üreten istekler ve ürettikleri token'ların bellekteki
/// yaşam döngüsü. Kurallar (alan yolu, süre, çakışma) Core'da `TokenFactory`;
/// burası yalnızca ağ çağrısını, önbelleği ve arayüz durumunu yönetir.
///
/// Token hiçbir zaman diske yazılmaz: ne workspace'e ne vault'a ne geçmişe.
/// Gönderimde isteğe `{{secret:token-factory/<ad>}}` olarak bağlanır ve değer
/// `OverlaySecretStore` ile yalnızca o gönderim için verilir.

extension AppState {
    // MARK: - Kaynaklar

    func tokenSources(for environment: EnvironmentModel?) -> [TokenFactory.Source] {
        TokenFactory.sources(in: workspace.tokenFactoryRequests, environment: environment)
    }

    func isTokenFactoryRequest(_ id: UUID) -> Bool {
        collection(containing: id)?.isTokenFactory == true
    }

    /// Token Factory'ye yeni istek ekler ve açar. İlk istek varsayılan adları
    /// alır (`token`, `access_token`); sonrakiler çakışmasın diye numaralanır.
    func addTokenFactoryRequest() {
        clearSearch()
        let factoryID = workspace.ensureTokenFactoryCollection()
        guard let index = workspace.collections.firstIndex(id: factoryID) else { return }
        let request = RequestModel(
            name: "Token İsteği",
            method: .post,
            tokenOutput: TokenOutput(variableName: uniqueTokenVariableName(base: TokenOutput.defaultVariableName))
        )
        workspace.collections[index].requests.append(request)
        showRequest(request.id)
        persist()
    }

    /// Normal istekleri Token Factory'ye KOPYALAR; asılları yerinde kalır.
    ///
    /// Taşıma değil: oradaki istek tüm isteklere token yazar; elle denenmiş bir
    /// login isteğinin koleksiyondan kaybolması beklenmez (bkz. `moveRequests`).
    /// Her kopya kendi değişken adını alır, sıralama kenar çubuğundaki gibi.
    /// Son kopya Token sekmesinde açılır: yanıt alanı oradan ayarlanır.
    func copyToTokenFactory(_ ids: Set<UUID>) {
        let picked = workspace.collections
            .filter { !$0.isTokenFactory }
            .flatMap(\.requests)
            .filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return }
        clearSearch()
        let factoryID = workspace.ensureTokenFactoryCollection()
        guard let index = workspace.collections.firstIndex(id: factoryID) else { return }
        for var request in picked {
            request.id = UUID()
            request.name = CollectionPorting.uniqueName(
                request.name,
                suffix: "kopya",
                existingNames: workspace.collections[index].requests.map(\.name)
            )
            request.tokenOutput = TokenOutput(variableName: uniqueTokenVariableName(base: TokenOutput.defaultVariableName))
            workspace.collections[index].requests.append(request)
        }
        guard let last = workspace.collections[index].requests.last else { return }
        showRequest(last.id)
        editorTab = .token
        persist()
    }

    /// Token Factory'de kullanılmayan değişken adı: `token`, `token2`, `token3`…
    func uniqueTokenVariableName(base: String) -> String {
        let root = TokenFactory.isValidVariableName(base) ? base : TokenOutput.defaultVariableName
        let taken = Set(workspace.tokenFactoryRequests.map { ($0.tokenOutput ?? TokenOutput()).trimmedVariableName })
        if !taken.contains(root) { return root }
        return (2...).lazy.map { "\(root)\($0)" }.first { !taken.contains($0) } ?? root
    }

    // MARK: - Token yaşam döngüsü

    /// Önbellek anahtarı; kural `TokenCacheKey`'te (Core, testli): istek,
    /// yanıt ayarı ya da kullandığı environment değeri değişince token düşer.
    func tokenKey(_ source: TokenFactory.Source, environment: EnvironmentModel?) -> TokenCacheKey {
        TokenCacheKey(source: source, environment: environment)
    }

    /// Artık hiçbir gönderimde kullanılamayacak token'ları bellekten atar.
    ///
    /// Her workspace düzenlemesi kayıttan (`persist`/`persistSoon`) geçtiği
    /// için oradan çağrılır: gövdeyi ya da `{{customerNo}}`'yu değiştirince eski
    /// token kullanılmamakla kalmaz, bellekte de beklemez; paneldeki durum
    /// noktası da söner. Yenisi arka planda değil, ilk ihtiyaçta alınır —
    /// yazarken her tuşta token sunucusuna gidilmesin.
    /// Anahtar workspace'in ŞU ANKİ halinde hâlâ kullanılabilir mi.
    func isLive(_ key: TokenCacheKey) -> Bool {
        TokenFactory.liveCacheKeys(in: workspace).contains(key)
    }

    func dropStaleTokens() {
        guard !tokenCache.isEmpty || !tokenStates.isEmpty else { return }
        let live = TokenFactory.liveCacheKeys(in: workspace)
        tokenCache = tokenCache.filter { live.contains($0.key) }
        let states = tokenStates.filter { live.contains($0.key) }
        // Gözlenen durum: değişmediyse yazma, panel boşuna yeniden çizilmesin.
        if states.count != tokenStates.count { tokenStates = states }
    }

    func tokenState(_ source: TokenFactory.Source, environment: EnvironmentModel?) -> TokenState? {
        tokenStates[tokenKey(source, environment: environment)]
    }

    /// Bellekteki token geçerliyse onu, değilse (yoksa ya da süresinin
    /// bitmesine 10 sn'den az kaldıysa) yenisini döner.
    func validToken(
        _ source: TokenFactory.Source,
        environment: EnvironmentModel?,
        forceRefresh: Bool = false
    ) async throws -> TokenFactory.IssuedToken {
        let key = tokenKey(source, environment: environment)
        if !forceRefresh, let cached = tokenCache[key], !cached.needsRefresh() { return cached }
        if let running = tokenFetches[key] {
            do {
                return try await running.value
            } catch {
                throw TokenError(variable: source.variable, reason: error.localizedDescription)
            }
        }

        // Token isteği environment'ın KENDİ değişkenleriyle gider; token
        // değişkenleri bağlanmaz (token isteği başka token'a bağlı olamaz,
        // bkz. `TokenFactory.Problem.usesFactoryVariable`).
        let engine = engine
        let store = secretStore
        let policy = hostPolicy
        let approvals = approvalStore.load()
        let request = source.request
        let output = source.output
        let task = Task { () throws -> TokenFactory.IssuedToken in
            let response: ResponseData
            do {
                response = try await engine.send(
                    request,
                    environment: environment,
                    secretStore: store,
                    hostPolicy: policy,
                    approvedWarnings: approvals
                )
            } catch RequestEngineError.needsApproval {
                // Onay ekranı token alırken gösterilemez; kullanıcı token
                // isteğini bir kez kendisi gönderip onaylamalı.
                throw TokenFetchError(
                    message: "token isteği \"\(request.name)\" güvenlik onayı bekliyor. "
                        + "Token Factory'de isteği açıp bir kez gönder ve onayla."
                )
            }
            return try TokenFactory.issue(statusCode: response.statusCode, body: response.body, output: output)
        }
        tokenFetches[key] = task
        tokenStates[key] = .fetching
        defer { tokenFetches[key] = nil }
        do {
            let token = try await task.value
            // Bekleyen gönderim token'ı yine kullanır; ama alınırken istek ya
            // da değer değiştiyse eski hal için gelen token saklanmaz.
            if isLive(key) {
                tokenCache[key] = token
                tokenStates[key] = .valid(expiresAt: token.expiresAt)
            }
            return token
        } catch {
            tokenCache[key] = nil
            tokenStates[key] = isLive(key) ? .failed(error.localizedDescription) : nil
            throw TokenError(variable: source.variable, reason: error.localizedDescription)
        }
    }

    /// Gönderim için environment ve secret deposu: kullanılan her token
    /// geçerli bir değere bağlanır. Biri alınamazsa istek gönderilmez.
    func prepareTokens(
        _ sources: [TokenFactory.Source],
        environment: EnvironmentModel?,
        forceRefresh: Bool = false
    ) async throws -> (EnvironmentModel?, SecretStore) {
        guard !sources.isEmpty else { return (environment, secretStore) }
        var overrides: [String: String] = [:]
        for source in sources {
            overrides[source.secretName] = try await validToken(
                source,
                environment: environment,
                forceRefresh: forceRefresh
            ).value
        }
        return (
            TokenFactory.environmentForSend(environment, sources: sources),
            OverlaySecretStore(base: secretStore, overrides: overrides)
        )
    }

    func forgetToken(_ source: TokenFactory.Source, environment: EnvironmentModel?) {
        let key = tokenKey(source, environment: environment)
        tokenCache[key] = nil
        tokenStates[key] = nil
    }

    /// Kullanıcı Token Factory isteğini kendisi gönderdi: yanıt token'ı
    /// güncellesin. "Token Factory işlemleri orada olsun" — isteği elle
    /// denemek ile token'ı yenilemek aynı hareket.
    ///
    /// Token, isteğin GÖNDERİLEN haline göre saklanır: yanıt beklenirken istek
    /// düzenlendiyse bu yanıt eski halin token'ıdır, saklanmaz.
    func absorbTokenResponse(_ request: RequestModel, response: ResponseData, environment: EnvironmentModel?) {
        guard tokenSources(for: environment).contains(where: { $0.request.id == request.id }),
              let source = TokenFactory.sources(in: [request], environment: environment).first else { return }
        let key = tokenKey(source, environment: environment)
        do {
            let token = try TokenFactory.issue(statusCode: response.statusCode, body: response.body, output: source.output)
            guard isLive(key) else { return }
            tokenCache[key] = token
            tokenStates[key] = .valid(expiresAt: token.expiresAt)
        } catch {
            tokenCache[key] = nil
            tokenStates[key] = isLive(key) ? .failed(error.localizedDescription) : nil
            showTokenAlert("{{\(source.variable)}} güncellenemedi: \(error.localizedDescription)", for: request.id)
        }
    }

    /// Alandaki `{{token}}` baloncuğu için bellekteki token (aktif
    /// environment'ta). Ağa çıkılmaz; alınmadıysa `nil`.
    func cachedToken(forVariable variable: String) -> TokenFactory.IssuedToken? {
        let environment = activeEnvironment
        guard let source = tokenSources(for: environment).first(where: { $0.variable == variable }) else { return nil }
        return tokenCache[tokenKey(source, environment: environment)]
    }

    /// cURL dışa aktarımı için: bellekte geçerli token varsa o, yoksa değişken
    /// adı (`{{token}}`) yazılır. Token almak için ağa ÇIKILMAZ.
    func cachedTokenBindings(for environment: EnvironmentModel?) -> (EnvironmentModel?, SecretStore) {
        let sources = tokenSources(for: environment)
        guard !sources.isEmpty else { return (environment, secretStore) }
        var overrides: [String: String] = [:]
        for source in sources {
            let cached = tokenCache[tokenKey(source, environment: environment)]
            overrides[source.secretName] = cached.flatMap { $0.needsRefresh() ? nil : $0.value }
                ?? "{{\(source.variable)}}"
        }
        return (
            TokenFactory.environmentForSend(environment, sources: sources),
            OverlaySecretStore(base: secretStore, overrides: overrides)
        )
    }

    /// "Token'ı yenile ve tekrar gönder": isteğin GÜNCEL hali, token'lar
    /// zorla yenilenerek yeniden gönderilir.
    func refreshTokensAndResend(_ requestID: UUID) {
        guard let request = request(withID: requestID) else { return }
        send(request, refreshingTokens: true)
    }

    /// "Yine de gönder (token olmadan)": token alınamadıktan sonra isteğin
    /// GÜNCEL hali Token Factory'ye gidilmeden gönderilir.
    func sendWithoutTokens(_ requestID: UUID) {
        guard let request = request(withID: requestID) else { return }
        tokenAlert = nil
        send(request, skippingTokens: true)
    }

    /// Öneriden ilgili Token Factory isteğine gider (token içeriğini kontrol et).
    func openTokenRequest(producing variable: String) {
        guard let source = tokenSources(for: activeEnvironment).first(where: { $0.variable == variable }) else { return }
        showRequest(source.request.id)
        editorTab = .token
    }

    func showTokenAlert(_ message: String, for requestID: UUID) {
        tokenAlert = TokenAlert(requestID: requestID, message: message)
    }

    func dismissTokenAlert(_ id: UUID) {
        if tokenAlert?.id == id { tokenAlert = nil }
    }

    struct TokenFetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

// MARK: - Tipler

extension AppState {
    enum TokenState: Equatable {
        case fetching
        case valid(expiresAt: Date?)
        case failed(String)
    }

    struct TokenError: LocalizedError {
        let variable: String
        let reason: String
        var errorDescription: String? { "{{\(variable)}} için token alınamadı; istek gönderilmedi. \(reason)" }
    }

    /// Alttan çıkıp kendiliğinden kaybolan uyarı. Yalnızca ait olduğu istek
    /// açıkken görünür; kimlik her gösterimde yenilenir ki aynı metin art
    /// arda gelse de zamanlayıcı baştan başlasın.
    struct TokenAlert: Equatable, Identifiable {
        let id = UUID()
        let requestID: UUID
        let message: String
    }
}
