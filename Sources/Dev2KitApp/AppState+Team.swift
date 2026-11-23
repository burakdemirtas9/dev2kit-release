import Foundation
import Dev2KitCore

// MARK: - Kurum collection'ları (dev2kit-auth / dev2kit-data, 2026-11-11)
//
// Kurallar Core'da: oturum `TeamSession`, servis `TeamDataClient`, içerik
// `TeamCollectionCodec`, koruma ve yerleşme `TeamSync`, önbellek `TeamCache`.
// Burada yalnızca akış ve durum.

extension AppState {
    /// İmzalı pakette Keychain (uygulamanın kendi kaydı; onay istemez).
    /// İmzasız ya da deneme dizininde `nil`: refresh token yalnızca bellekte
    /// (rehber: dosyada tutma yok), her açılışta yeniden giriş.
    nonisolated static func teamRefreshTokenStore() -> SecretStore? {
        guard CodeSigningStatus.hasTeamIdentity, !AppPaths.isOverridden else { return nil }
        return KeychainSecretStore(service: "com.dev2kit.team")
    }

    var teamClient: TeamDataClient { TeamDataClient(session: teamSession) }

    var teamIdentity: TeamIdentity? {
        if case .loggedIn(let identity) = teamStatus { return identity }
        return nil
    }

    func isTeamCollection(_ id: UUID) -> Bool { teamCatalog.isTeam(id) }

    /// Seçili isteğin kurum collection'ı (istek ekranındaki bant için).
    func teamCollectionID(containing requestID: UUID) -> UUID? {
        guard !teamCatalog.entries.isEmpty, let located = locateRequest(requestID) else { return nil }
        let id = workspace.collections[located.collection].id
        return teamCatalog.isTeam(id) ? id : nil
    }

    // MARK: Koruma

    /// Workspace her değiştiğinde: düzenlenemeyen kurum collection'ına
    /// dokunulduysa geri alınır, düzenlenebilen değiştiyse "kaydedilmedi".
    func enforceTeamRules(previous: WorkspaceModel) {
        guard previous.collections != workspace.collections else { return }
        let result = TeamSync.enforce(old: previous.collections, new: workspace.collections, catalog: teamCatalog)
        if result.blocked {
            applyTeam { $0.workspace.collections = result.collections }
            teamNotice = L10n.t("team.readOnly.blocked")
        }
        for id in result.dirtied where teamCatalog.entries[id]?.isDirty == false {
            teamCatalog.entries[id]?.isDirty = true
        }
        // Kurum collection'ları workspace kaydına girmez: kaydedilmemiş
        // düzenleme önbelleğe yazılmazsa uygulama kapanınca sessizce kaybolur.
        // Yazım burada değil (her tuşta çalışır), workspace kaydıyla birlikte.
        if !result.dirtied.isEmpty || !result.localChanged.isEmpty { teamCacheNeedsSave = true }
    }

    /// Kurum yerleşimini korumadan geçirmeden uygular (servisten gelen hal).
    func applyTeam(_ change: (AppState) -> Void) {
        isApplyingTeam = true
        change(self)
        isApplyingTeam = false
    }

    // MARK: Açılış

    func loadTeamCache() {
        guard let cache = TeamCache.load(root: store.layout.root) else { return }
        applyTeam { state in
            state.teamCatalog = cache.catalog
            let ids = Set(cache.collections.map(\.id))
            state.workspace.collections.removeAll { ids.contains($0.id) }
            state.workspace.collections.insert(contentsOf: cache.collections, at: 0)
        }
        teamCanCreate = cache.canCreate
    }

    /// Kurum bölümü ilk göründüğünde: saklı oturum varsa sürdürülür.
    func teamStart() async {
        guard teamStatus == .unknown else { return }
        teamStatus = .restoring
        do {
            if let identity = try await teamSession.restore() {
                await didSignIn(identity)
            } else {
                endTeamSession(keepNotice: false)
            }
        } catch TeamError.sessionExpired {
            endTeamSession(keepNotice: false)
        } catch {
            // Servise ulaşılamıyor: saklı oturum düşürülmez, önbellek salt
            // okunur kalır; bölümde "Tekrar dene" (`teamStatus == .unknown`).
            markCacheReadOnly()
            teamStatus = .unknown
            teamNotice = error.localizedDescription
        }
    }

    /// Çevrimdışı açılış: önbellekteki collection'lar düzenlenemez.
    private func markCacheReadOnly() {
        for id in teamCatalog.entries.keys { teamCatalog.entries[id]?.isLoaded = false }
    }

    // MARK: Giriş / çıkış

    /// Başarısız login otomatik tekrarlanmaz; 429'da düğme süre dolana dek kapalı.
    func teamLogin(username: String, password: String) async -> String? {
        if let until = teamLoginRetryAt, until > Date() {
            return TeamError.tooManyAttempts(retryAfter: Int(until.timeIntervalSinceNow.rounded(.up))).localizedDescription
        }
        do {
            let identity = try await teamSession.login(username: username.trimmingCharacters(in: .whitespaces), password: password)
            teamLoginRetryAt = nil
            showingTeamLogin = false
            await didSignIn(identity)
            return nil
        } catch TeamError.tooManyAttempts(let seconds) {
            teamLoginRetryAt = Date().addingTimeInterval(TimeInterval(seconds))
            return TeamError.tooManyAttempts(retryAfter: seconds).localizedDescription
        } catch {
            return error.localizedDescription
        }
    }

    private func didSignIn(_ identity: TeamIdentity) async {
        let previousGroup = teamIdentity?.group
        teamStatus = .loggedIn(identity)
        teamNotice = nil
        if previousGroup != identity.group { teamCanCreate = false }
        await teamRefresh()
    }

    func teamLogout() async {
        await teamSession.logout()
        endTeamSession(keepNotice: false)
    }

    /// Oturum bitti ya da çıkıldı: kurum collection'ları ve önbellek gider.
    /// Kaydedilmemiş değişikliği olanlar atılmaz: kendi collection'larına
    /// kopyalanır (`TeamSync.rescueCopies`) ve kullanıcıya söylenir. Dönen
    /// değer kopyaların adları.
    @discardableResult
    func endTeamSession(keepNotice: Bool) -> [String] {
        let ids = Set(teamCatalog.entries.keys)
        let rescued = rescueCopies(dropping: ids)
        applyTeam { state in
            state.teamCatalog = TeamCatalog()
            state.workspace.collections.removeAll { ids.contains($0.id) }
            state.workspace.collections.append(contentsOf: rescued)
        }
        pruneTabs()
        // Kopyalar artık kullanıcının kendi collection'ı: workspace'e yazılır.
        if !rescued.isEmpty { persist() }
        TeamCache.delete(root: store.layout.root)
        teamCanCreate = false
        teamConflictID = nil
        teamRemoteChangedIDs = []
        teamStatus = .loggedOut
        if !keepNotice { teamNotice = nil }
        let names = rescued.map(\.name)
        if let notice = rescueNotice(names) { teamNotice = notice }
        return names
    }

    /// Atılacak kurum collection'larından kaydedilmemiş olanların kopyaları.
    private func rescueCopies(dropping ids: Set<UUID>) -> [CollectionModel] {
        TeamSync.rescueCopies(dropping: ids, from: workspace.collections, catalog: teamCatalog,
                              suffix: L10n.t("team.copySuffix"))
    }

    private func rescueNotice(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return L10n.t("team.rescued", names.map { "“\($0)”" }.joined(separator: ", "))
    }

    /// Hata ortak işleme: oturum bittiyse çıkış, yetki/silinme değiştiyse yenile.
    private func handleTeamError(_ error: Error) async {
        switch error as? TeamError {
        case .sessionExpired?, .notLoggedIn?:
            let rescued = endTeamSession(keepNotice: true)
            teamNotice = [TeamError.sessionExpired.localizedDescription, rescueNotice(rescued)]
                .compactMap { $0 }.joined(separator: " ")
        case .forbidden?, .notFound?:
            teamNotice = error.localizedDescription
            await teamRefresh()
        default:
            teamNotice = error.localizedDescription
        }
    }

    // MARK: Liste ve içerik

    /// `/me` + liste. Grup değiştiyse yetkiler yeniden okunur (rehber §6).
    /// `reloadLoaded`: kullanıcı Yenile'ye bastı; çekilmiş collection'lar sürümü
    /// aynı görünse de sunucudan yeniden alınır. Kaydedilmemiş değişikliği olan
    /// ezilmez: sunucuda değiştiyse sorulur (`teamRemoteChangedIDs`).
    func teamRefresh(reloadLoaded: Bool = false) async {
        guard teamIdentity != nil, !teamIsRefreshing else { return }
        teamIsRefreshing = true
        defer { teamIsRefreshing = false }
        do {
            if let current = await teamSession.identity, current != teamIdentity { teamStatus = .loggedIn(current) }
            teamCanCreate = try await teamClient.me().canCreate
            let summaries = try await teamClient.list()
            let ownGroup = teamIdentity?.group
            let known = Set(teamCatalog.entries.keys)
            let previouslyLoaded = Set(teamCatalog.entries.filter(\.value.isLoaded).keys)
            let merged = TeamSync.merge(summaries, into: workspace.collections, catalog: teamCatalog, ownGroup: ownGroup)
            // Sunucuda artık olmayan (silinmiş, erişimi kalkmış) collection'daki
            // kaydedilmemiş çalışma listeyle birlikte gitmesin.
            let rescued = rescueCopies(dropping: known.subtracting(merged.catalog.entries.keys))
            applyTeam { state in
                state.teamCatalog = merged.catalog
                state.workspace.collections = merged.collections + rescued
            }
            if !rescued.isEmpty {
                persist()
                teamNotice = rescueNotice(rescued.map(\.name))
            }
            // Başka ekiplerin yeni collection'ları kapalı başlar: içerik açılınca çekilir.
            for (id, info) in merged.catalog.entries where !known.contains(id) && info.summary.ownerGroup != ownGroup {
                collapsedCollectionIDs.insert(id)
            }
            pruneTabs()
            saveTeamCache()
            teamRemoteChangedIDs = merged.remoteChanged
            let targets = TeamSync.reloadTargets(order: merged.collections.map(\.id), catalog: merged.catalog,
                                                 previouslyLoaded: previouslyLoaded,
                                                 collapsed: collapsedCollectionIDs, reloadLoaded: reloadLoaded)
            for id in targets { await teamReload(id) }
        } catch {
            await handleTeamError(error)
        }
    }

    /// İçeriği sunucudan yeniden alır. İstek sürerken kullanıcı düzenlemeye
    /// başladıysa yerel çalışma ezilmez; sunucu farklı sürümdeyse sorulur.
    func teamReload(_ id: UUID) async {
        guard let info = teamCatalog.entries[id], !info.isDirty, !teamLoadingIDs.contains(id), teamIdentity != nil else { return }
        teamLoadingIDs.insert(id)
        defer { teamLoadingIDs.remove(id) }
        do {
            let detail = try await teamClient.fetch(id: info.summary.id)
            guard let current = teamCatalog.entries[id] else { return }
            if current.isDirty {
                if detail.summary.version != current.summary.version, !teamRemoteChangedIDs.contains(id) {
                    teamRemoteChangedIDs.append(id)
                }
                return
            }
            try apply(detail)
        } catch {
            await handleTeamError(error)
        }
    }

    /// Sunucuda değişmiş, yerelde kaydedilmemiş collection için kullanıcının kararı.
    func teamResolveRemoteChange(_ id: UUID, loadServer: Bool) async {
        teamRemoteChangedIDs.removeAll { $0 == id }
        if loadServer { await teamResolveConflictByReloading(id) }
    }

    func teamLoad(_ id: UUID) async {
        guard let info = teamCatalog.entries[id], !info.isLoaded, !teamLoadingIDs.contains(id), teamIdentity != nil else { return }
        teamLoadingIDs.insert(id)
        defer { teamLoadingIDs.remove(id) }
        do {
            try apply(await teamClient.fetch(id: info.summary.id))
        } catch {
            await handleTeamError(error)
        }
    }

    private func apply(_ detail: TeamCollectionDetail) throws {
        let result = try TeamSync.apply(detail, to: workspace.collections, catalog: teamCatalog)
        applyTeam { state in
            state.teamCatalog = result.catalog
            state.workspace.collections = result.collections
        }
        if result.skipped > 0 { teamNotice = L10n.t("team.skippedRequests", L10n.number(result.skipped)) }
        saveTeamCache()
    }

    /// Önbelleği arka planda yazar (workspace ve geçmişle aynı seri kuyruk:
    /// kapanıştaki bekleme bunu da kapsar). Kaydedilmemiş düzenlemeler de
    /// buradadır; yazılamazsa tanılama günlüğüne düşer.
    func saveTeamCache() {
        guard let identity = teamIdentity else { return }
        teamCacheNeedsSave = false
        let ids = Set(teamCatalog.entries.keys)
        let cache = TeamCache(identity: identity, canCreate: teamCanCreate, catalog: teamCatalog,
                              collections: workspace.collections.filter { ids.contains($0.id) })
        let root = store.layout.root
        PersistenceQueue.shared.async {
            do {
                try cache.save(root: root)
            } catch {
                DiagnosticLog.shared.record(DiagnosticEvent(kind: .storageSaveFailed, error: error))
            }
        }
    }

    // MARK: Yazma (izne göre)

    /// Belge ve kimlik bilgisi denetimi (gövdelerde regex taraması) ana iş
    /// parçacığı dışında: collection 5 MB'a kadar olabilir (UI-KURALLARI §4).
    nonisolated private static func encodeForTeam(_ collection: CollectionModel) async throws -> Data {
        try await BackgroundWork.run { Result { try TeamCollectionCodec.encode(collection) } }.get()
    }

    /// Kaydedilmemiş değişikliği sunucuya gönderir (sürümle). 409 otomatik
    /// tekrarlanmaz: kullanıcıya sorulur (`teamConflictID`).
    func teamSave(_ id: UUID) async {
        guard let info = teamCatalog.entries[id], let collection = workspace.collections.first(where: { $0.id == id }) else { return }
        do {
            let content = try await Self.encodeForTeam(collection)
            try apply(await teamClient.update(id: info.summary.id, name: collection.name, content: content, version: info.summary.version))
            teamNotice = nil
        } catch TeamError.versionConflict {
            teamConflictID = id
        } catch {
            await handleTeamError(error)
        }
    }

    /// Kurum bölümünün başlığındaki "Sunucuya kaydet": kaydedilmemiş tüm
    /// düzenlenebilen collection'ları sırayla kaydeder (`TeamCatalog.savableIDs`).
    /// İlk çakışma ya da hatada durur: çakışma kutusu tek collection için, hata
    /// bildirimi de o collection'ı anlatır; kalanlar kaydedilmedi olarak kalır.
    func teamSaveAll() async {
        guard !teamIsSavingAll else { return }
        teamIsSavingAll = true
        defer { teamIsSavingAll = false }
        for id in teamCatalog.savableIDs(in: workspace.collections.map(\.id)) {
            await teamSave(id)
            if teamConflictID != nil || teamCatalog.entries[id]?.isDirty == true { break }
        }
    }

    /// Çakışma: sunucudaki hali yükle (yerel değişiklik gider).
    func teamResolveConflictByReloading(_ id: UUID) async {
        teamConflictID = nil
        guard let info = teamCatalog.entries[id] else { return }
        do {
            try apply(await teamClient.fetch(id: info.summary.id))
        } catch {
            await handleTeamError(error)
        }
    }

    /// Çakışma: kullanıcı onayıyla yerel hali en yeni sürümün üzerine kaydet.
    func teamResolveConflictByOverwriting(_ id: UUID) async {
        teamConflictID = nil
        guard let info = teamCatalog.entries[id], let collection = workspace.collections.first(where: { $0.id == id }) else { return }
        do {
            let latest = try await teamClient.fetch(id: info.summary.id)
            let content = try await Self.encodeForTeam(collection)
            try apply(await teamClient.update(id: info.summary.id, name: collection.name, content: content, version: latest.summary.version))
        } catch TeamError.versionConflict {
            teamConflictID = id
        } catch {
            await handleTeamError(error)
        }
    }

    /// Yeni boş kurum collection'ı (yalnızca `canCreate`).
    func teamCreate(name: String) async -> String? {
        do {
            let content = try TeamCollectionCodec.encode(CollectionModel(name: name))
            try apply(await teamClient.create(name: name.trimmingCharacters(in: .whitespaces), content: content))
            await teamRefresh()
            return nil
        } catch {
            if case TeamError.sessionExpired = error { await handleTeamError(error) }
            return error.localizedDescription
        }
    }

    /// Kendi collection'ını kuruma yayınlar (yeni kimliklerle; gizli bilgi kontrolünden geçer).
    func teamPublish(_ id: UUID) async {
        guard let collection = workspace.collections.first(where: { $0.id == id }), !isTeamCollection(id) else { return }
        do {
            let copy = CollectionPorting.copyWithNewIDs(collection, name: collection.name)
            let content = try await Self.encodeForTeam(copy)
            try apply(await teamClient.create(name: collection.name, content: content))
            await teamRefresh()
            teamNotice = L10n.t("team.published", collection.name)
        } catch {
            await handleTeamError(error)
        }
    }

    /// Sunucuda siler (geri alınamaz; onay ekranda), sonra yerelden kaldırır.
    func teamDelete(_ id: UUID) async {
        guard let info = teamCatalog.entries[id] else { return }
        do {
            try await teamClient.delete(id: info.summary.id)
            applyTeam { state in
                state.teamCatalog.entries[id] = nil
                state.workspace.collections.removeAll { $0.id == id }
            }
            pruneTabs()
            saveTeamCache()
        } catch {
            await handleTeamError(error)
        }
    }

    /// Kurum collection'ının düzenlenebilir kopyası kendi collection'larına.
    func teamCopyToMine(_ id: UUID) {
        guard let collection = workspace.collections.first(where: { $0.id == id }) else { return }
        let names = workspace.collections.map(\.name)
        let name = CollectionPorting.uniqueName(collection.name, suffix: L10n.t("team.copySuffix"), existingNames: names)
        let copy = CollectionPorting.copyWithNewIDs(collection, name: name)
        workspace.collections.append(copy)
        persist()
        teamNotice = L10n.t("team.copied", name)
    }
}
