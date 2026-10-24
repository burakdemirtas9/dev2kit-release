import Foundation

/// Workspace'in dosya tabanlı deposu (şema 3). Yerleşim: `StoreLayout`.
///
/// - **Encode önbelleği:** içeriği son kayıttakiyle aynı olan dosya yeniden
///   encode edilmez ve özetlenmez (`EncodeCache`); kayıt maliyeti değişen
///   dosya kadar. Önbellek yalnızca değer + özet tutar, bayt tutmaz.
///
/// - **Yazım:** yalnızca değişen dosyalar. Tek isteği düzenlemek kendi
///   koleksiyon dosyasını ve manifest'i yazar; eskiden her tuş vuruşunda tüm
///   workspace yeniden yazılıyordu.
/// - **Çok dosyalı işlem:** yeni dosyalar `staging`'e → günlük (journal,
///   commit noktası) → yerine taşıma → manifest → günlük silinir. Yarıda
///   kalırsa açılışta ileri doğru tamamlanır. Dosya başına atomiklik
///   (`AtomicFile`) tek başına yetmez: iki dosyadan biri yazılıp öteki
///   yazılmadan kesilirse koleksiyon ile sıra birbirini tutmaz.
/// - **Doğrulama:** her dosyanın özeti manifest'te; tutmayan dosya okunmuş
///   sayılmaz.
/// - **Bozulma:** okunamayan dosyalar karantinaya KOPYALANIR (silinmez), son
///   sağlam yedek yüklenir; yedek yoksa okunabilen kısım yüklenir ve kayıp
///   kullanıcıya söylenir. Hiçbir durumda sessizce boş veri yazılmaz.
/// - **Yedek:** açılışta doğrulanmış hal ve oturum boyunca saatte bir, son 5.
///
/// Secret'lar burada asla yer almaz (yalnızca `{{secret:...}}` referansları).
public final class WorkspaceStore: @unchecked Sendable {
    public let layout: StoreLayout
    private let lock = NSLock()
    /// Diskte geçerli olan manifest: değişiklik karşılaştırması buna göre.
    private var committed: StoreManifest?
    private var lastBackup: Date?
    private let clock: @Sendable () -> Date
    /// Değişmeyen dosyalar her kayıtta yeniden encode edilip özetlenmesin.
    private let encodeCache = EncodeCache()

    public static let keptBackups = 5
    public static let backupInterval: TimeInterval = 3_600

    public init(directory: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.layout = StoreLayout(root: directory ?? AppPaths.supportDirectory)
        self.clock = clock
    }

    // MARK: - Açılış

    public struct OpenResult {
        public var workspace: WorkspaceModel
        public var notices: [StoreNotice]
    }

    /// Workspace'i açar: yarım işlemi tamamlar, gerekirse şema 1'den taşır,
    /// bozuk dosyada yedeğe döner. Yalnızca veri ezilmeden devam
    /// edilemeyecekse hata atar (daha yeni şema, tamamlanamayan işlem).
    public func open() throws -> OpenResult {
        lock.lock(); defer { lock.unlock() }
        var notices: [StoreNotice] = []
        let manager = FileManager.default
        try ensureDirectory(layout.root)

        if manager.fileExists(atPath: layout.manifest.path) || manager.fileExists(atPath: layout.journal.path) {
            if try recoverJournalLocked() { notices.append(.recoveredInterruptedSave) }
        }
        try? manager.removeItem(at: layout.staging)
        AtomicFile.removeLeftovers(in: layout.root)

        guard manager.fileExists(atPath: layout.manifest.path) else {
            if manager.fileExists(atPath: layout.legacyWorkspace.path) {
                let (workspace, notice) = try migrateLegacyLocked()
                notices.append(notice)
                backUpIfDueLocked(force: true)
                return OpenResult(workspace: workspace, notices: notices)
            }
            if manager.fileExists(atPath: layout.store.path), hasContent(layout.store) {
                // Manifest yok ama dosyalar var: dışarıdan bozulma.
                return OpenResult(workspace: try recoverLocked(reason: [L10n.t("store.file.manifest")], notices: &notices),
                                  notices: notices)
            }
            committed = nil
            return OpenResult(workspace: WorkspaceModel(schemaVersion: StoreManifest.currentSchema), notices: notices)
        }

        switch Self.read(layout.store) {
        case .success(let state):
            committed = state.manifest
            settleLegacyLeftoverLocked()
            backUpIfDueLocked(force: true)
            return OpenResult(workspace: state.workspace, notices: notices)
        case .failure(let failure):
            if case .newerSchema(let found) = failure.kind {
                throw StoreError.newerSchema(found: found, supported: StoreManifest.currentSchema)
            }
            return OpenResult(workspace: try recoverLocked(reason: failure.unreadable, notices: &notices), notices: notices)
        }
    }

    /// Testler ve basit kullanım için: açar ve workspace'i döner.
    public func load() throws -> WorkspaceModel { try open().workspace }

    // MARK: - Kayıt

    /// Anlık görüntüyü yazar; yalnızca değişen dosyalar. Hata atarsa diskteki
    /// geçerli hal değişmemiştir (ya da bekleyen işlem açılışta tamamlanır).
    public func save(_ workspace: WorkspaceModel) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory(layout.root)
        // Önceki işlem yarım kaldıysa önce o tamamlanır: üstüne yeni işlem kurulmaz.
        if FileManager.default.fileExists(atPath: layout.journal.path) {
            _ = try recoverJournalLocked()
        }
        let encoded = try Self.encodeWithDigests(workspace, cache: encodeCache)
        let manifest = StoreManifest(
            schemaVersion: StoreManifest.currentSchema,
            activeEnvironmentID: workspace.activeEnvironmentID,
            collectionOrder: workspace.collections.map(\.id),
            files: encoded.digests
        )
        guard !manifest.sameContent(as: committed) else { return }
        // Yalnızca özeti değişen dosyalar; baytları yalnızca onlar için.
        var changed: [String: Data] = [:]
        for (path, digest) in encoded.digests where committed?.files[path] != digest {
            changed[path] = try encoded.data(for: path)
        }
        let removed = Set(committed?.files.keys.map { $0 } ?? []).subtracting(encoded.digests.keys)
        try commitLocked(writes: changed, deletes: Array(removed), manifest: manifest, in: layout.store)
        committed = manifest
        backUpIfDueLocked(force: false)
    }

    // MARK: - İşlem (journal)

    private func commitLocked(writes: [String: Data], deletes: [String], manifest: StoreManifest, in store: URL) throws {
        let id = UUID()
        let staging = store.appendingPathComponent("staging/\(id.uuidString)", isDirectory: true)
        do {
            for (path, data) in writes {
                try AtomicFile.write(data, to: staging.appendingPathComponent(path))
            }
        } catch {
            // Commit öncesi: geçerli hal bozulmadı, yarım staging temizlenir.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        let journal = StoreJournal(id: id, writes: writes.keys.sorted(), deletes: deletes.sorted(), manifest: manifest)
        try AtomicFile.write(try Self.encoder.encode(journal), to: store.appendingPathComponent("journal.json"))
        try apply(journal, in: store)
    }

    /// Günlüğü uygular; yarıda kesildiyse tekrar çağrılabilir (idempotent).
    private func apply(_ journal: StoreJournal, in store: URL) throws {
        let manager = FileManager.default
        for path in journal.writes + journal.deletes + Array(journal.manifest.files.keys)
        where !StoreLayout.isValidRelativePath(path) {
            throw StoreError.journalUnrecoverable(path)
        }
        let staging = store.appendingPathComponent("staging/\(journal.id.uuidString)", isDirectory: true)
        for path in journal.writes {
            let staged = staging.appendingPathComponent(path)
            let target = store.appendingPathComponent(path)
            if manager.fileExists(atPath: staged.path) {
                try ensureDirectory(target.deletingLastPathComponent())
                guard rename(staged.path, target.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else {
                // Önceki denemede taşınmış olmalı: içerik manifest'le tutmalı.
                guard let data = try? Data(contentsOf: target),
                      AtomicFile.digest(data) == journal.manifest.files[path] else {
                    throw StoreError.journalUnrecoverable(path)
                }
            }
        }
        for path in journal.deletes {
            try? manager.removeItem(at: store.appendingPathComponent(path))
        }
        try AtomicFile.write(try Self.encoder.encode(journal.manifest), to: store.appendingPathComponent("manifest.json"))
        try? manager.removeItem(at: store.appendingPathComponent("journal.json"))
        try? manager.removeItem(at: staging)
        // Boş kalan üst dizin de kalkar (başka süren işlem yoksa boştur).
        _ = rmdir(staging.deletingLastPathComponent().path)
    }

    /// Bekleyen günlük varsa tamamlar. Okunamayan günlük commit'e ulaşmamış
    /// sayılır (atomik yazıldığı için yarım olamaz; dışarıdan bozulmuştur):
    /// silinir, manifest ve özetler geçerli hali belirler.
    @discardableResult
    private func recoverJournalLocked() throws -> Bool {
        guard let data = try? Data(contentsOf: layout.journal) else { return false }
        guard let journal = try? JSONDecoder().decode(StoreJournal.self, from: data) else {
            try? FileManager.default.removeItem(at: layout.journal)
            return false
        }
        try apply(journal, in: layout.store)
        return true
    }

    // MARK: - Okuma ve doğrulama

    struct LoadedState {
        var workspace: WorkspaceModel
        var manifest: StoreManifest
    }

    struct ReadFailure: Error {
        enum Kind { case damaged, newerSchema(Int) }
        var kind: Kind
        /// Okunamayan ya da özeti tutmayan dosyalar (göreli yol).
        var unreadable: [String]
        /// Okunabilen kısım (kurtarma için).
        var partial: WorkspaceModel
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Özetler kararlı olsun (aynı içerik → aynı bayt) ve dosyalar okunabilir kalsın.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static func encode(_ workspace: WorkspaceModel) throws -> [String: Data] {
        try encodeWithDigests(workspace, cache: nil).fresh
    }

    /// Kaydın encode sonucu: tüm dosyaların özeti; baytlar yalnızca bu turda
    /// encode edilenler için tutulur, önbellekten gelenlerinki gerekirse
    /// (diskteki halden farklıysa) o an üretilir. Böylece önbellek dosya
    /// içeriklerini bellekte ikinci kez taşımaz.
    struct Encoded {
        var digests: [String: String] = [:]
        var fresh: [String: Data] = [:]
        var cached: [String: EncodeCache.Entry] = [:]

        func data(for path: String) throws -> Data {
            if let data = fresh[path] { return data }
            guard let entry = cached[path] else { throw CocoaError(.fileWriteUnknown) }
            return try entry.encode()
        }
    }

    /// Dosyalar ve özetleri. Örnekler istek başına ayrı dosyada (şema 3);
    /// koleksiyon dosyası örneksiz yazılır. `cache` verilirse içeriği son
    /// kayıttakiyle aynı olan dosya yeniden encode edilmez ve özetlenmez.
    ///
    /// Ölçüldü (2026-10-24, release, 20 istek × 5 × 1 MB örnek): önceden her
    /// kayıt (değişiklik olmasa da, başka koleksiyonda tek harf de) ~330–370 ms.
    static func encodeWithDigests(_ workspace: WorkspaceModel, cache: EncodeCache?) throws -> Encoded {
        var result = Encoded()
        func put<T: Encodable & Equatable>(_ value: T, at path: String) throws {
            if let hit = cache?.hit(for: value, at: path) {
                result.digests[path] = hit.digest
                result.cached[path] = hit
                return
            }
            let data = try encoder.encode(value)
            let digest = AtomicFile.digest(data)
            result.digests[path] = digest
            result.fresh[path] = data
            cache?.store(value, digest: digest, at: path)
        }
        for collection in workspace.collections {
            var stripped = collection
            for index in stripped.requests.indices where !stripped.requests[index].examples.isEmpty {
                let request = stripped.requests[index]
                try put(request.examples, at: StoreLayout.examplesPath(request.id))
                stripped.requests[index].examples = []
            }
            try put(stripped, at: StoreLayout.collectionPath(collection.id))
        }
        try put(workspace.environments, at: StoreLayout.environmentsPath)
        try put(StoreSettings(tlsProfiles: workspace.tlsProfiles, sentBaselines: workspace.sentBaselines),
                at: StoreLayout.settingsPath)
        cache?.retain(only: Set(result.digests.keys))
        return result
    }

    /// Koleksiyonlara örneklerini dosyalarından yerleştirir. Şema 2'de
    /// (2026-10-24 öncesi) örnekler koleksiyon dosyasının içindeydi: dosyası
    /// olmayan istekte o haliyle kalır, bir sonraki kayıt ayırır.
    static func attachExamples(to collections: inout [CollectionModel], load: (String) -> [ResponseExample]?) {
        for c in collections.indices {
            for r in collections[c].requests.indices {
                if let examples = load(StoreLayout.examplesPath(collections[c].requests[r].id)) {
                    collections[c].requests[r].examples = examples
                }
            }
        }
    }

    /// Dizindeki yapıyı okur ve her dosyayı manifest özetine göre doğrular.
    static func read(_ store: URL) -> Result<LoadedState, ReadFailure> {
        let decoder = JSONDecoder()
        var unreadable: [String] = []
        var partial = WorkspaceModel(schemaVersion: StoreManifest.currentSchema)

        func file<T: Decodable>(_ path: String, _ type: T.Type, expected: String?) -> T? {
            guard let data = try? Data(contentsOf: store.appendingPathComponent(path)),
                  expected == nil || AtomicFile.digest(data) == expected,
                  let value = try? decoder.decode(type, from: data) else {
                unreadable.append(path)
                return nil
            }
            return value
        }

        guard let manifestData = try? Data(contentsOf: store.appendingPathComponent("manifest.json")),
              var manifest = try? decoder.decode(StoreManifest.self, from: manifestData) else {
            // Manifest yok: özetsiz, okunabilen her şey kurtarılır.
            unreadable.append("manifest.json")
            partial.environments = file(StoreLayout.environmentsPath, [EnvironmentModel].self, expected: nil) ?? []
            if let settings = file(StoreLayout.settingsPath, StoreSettings.self, expected: nil) {
                partial.tlsProfiles = settings.tlsProfiles
                partial.sentBaselines = settings.sentBaselines
            }
            let collectionsDir = store.appendingPathComponent("collections")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: collectionsDir.path)) ?? []
            partial.collections = names.filter { $0.hasSuffix(".json") }.sorted()
                .compactMap { file("collections/\($0)", CollectionModel.self, expected: nil) }
            attachExamples(to: &partial.collections) { path in
                guard FileManager.default.fileExists(atPath: store.appendingPathComponent(path).path) else { return nil }
                return file(path, [ResponseExample].self, expected: nil)
            }
            return .failure(ReadFailure(kind: .damaged, unreadable: unreadable, partial: partial))
        }
        // Geçersiz yol taşıyan manifest bozuk sayılır (yedeğe dönülür).
        if let bad = manifest.files.keys.first(where: { !StoreLayout.isValidRelativePath($0) }) {
            unreadable.append(bad)
            return .failure(ReadFailure(kind: .damaged, unreadable: unreadable, partial: partial))
        }
        guard manifest.schemaVersion <= StoreManifest.currentSchema else {
            return .failure(ReadFailure(kind: .newerSchema(manifest.schemaVersion), unreadable: [], partial: partial))
        }
        StoreMigrations.upgrade(&manifest)

        partial.activeEnvironmentID = manifest.activeEnvironmentID
        partial.environments = file(StoreLayout.environmentsPath, [EnvironmentModel].self,
                                    expected: manifest.files[StoreLayout.environmentsPath]) ?? []
        if let settings = file(StoreLayout.settingsPath, StoreSettings.self, expected: manifest.files[StoreLayout.settingsPath]) {
            partial.tlsProfiles = settings.tlsProfiles
            partial.sentBaselines = settings.sentBaselines
        }
        partial.collections = manifest.collectionOrder.compactMap { id in
            file(StoreLayout.collectionPath(id), CollectionModel.self, expected: manifest.files[StoreLayout.collectionPath(id)])
        }
        // Örnek dosyası manifest'teyse okunur ve özeti doğrulanır; tutmazsa
        // diğer dosyalar gibi bozuk sayılır (karantina + yedek).
        attachExamples(to: &partial.collections) { path in
            guard let expected = manifest.files[path] else { return nil }
            return file(path, [ResponseExample].self, expected: expected)
        }
        // Sırada olmayan ama manifest'te dosyası olan koleksiyon (olmamalı).
        guard unreadable.isEmpty else {
            return .failure(ReadFailure(kind: .damaged, unreadable: unreadable, partial: partial))
        }
        return .success(LoadedState(workspace: partial, manifest: manifest))
    }

    // MARK: - Kurtarma

    /// Okunamayan dosyalar karantinaya kopyalanır; en yeni okunabilen yedek
    /// geri yüklenir. Yedek yoksa okunabilen kısım yüklenir ve bir sonraki
    /// kayıt tüm yapıyı baştan yazar (manifest yeniden kurulur).
    private func recoverLocked(reason unreadable: [String], notices: inout [StoreNotice]) throws -> WorkspaceModel {
        let quarantine = try quarantineLocked()
        for backup in backupsNewestFirst() {
            guard case .success(let state) = Self.read(backup) else { continue }
            try replaceStore(with: backup)
            committed = state.manifest
            notices.append(.restoredFromBackup(backup: backup, quarantine: quarantine))
            return state.workspace
        }
        let partial: WorkspaceModel
        if case .failure(let failure) = Self.read(layout.store) { partial = failure.partial } else { partial = WorkspaceModel() }
        // Kısmi hal hemen tutarlı biçimde yazılır: yarım manifest kalmasın.
        // Okunamayan dosyalar karantinada; yapıdan çıkarılır.
        let files = try Self.encode(partial)
        let manifest = StoreManifest(
            schemaVersion: StoreManifest.currentSchema,
            activeEnvironmentID: partial.activeEnvironmentID,
            collectionOrder: partial.collections.map(\.id),
            files: files.mapValues(AtomicFile.digest)
        )
        let collections = layout.store.appendingPathComponent("collections")
        let present = ((try? FileManager.default.contentsOfDirectory(atPath: collections.path)) ?? []).map { "collections/\($0)" }
        try commitLocked(writes: files, deletes: present.filter { files[$0] == nil }, manifest: manifest, in: layout.store)
        committed = manifest
        notices.append(.partiallyLoaded(lost: unreadable, quarantine: quarantine))
        return partial
    }

    /// `store` dizininin kopyası `quarantine/<zaman>/`. Kopyalanamazsa hata:
    /// ezilebilecek veri korunamıyorsa devam edilmez.
    private func quarantineLocked() throws -> URL {
        let target = uniqueDirectory(in: layout.quarantine)
        try ensureDirectory(layout.quarantine)
        if FileManager.default.fileExists(atPath: layout.store.path) {
            try FileManager.default.copyItem(at: layout.store, to: target)
        } else {
            try ensureDirectory(target)
        }
        return target
    }

    private func replaceStore(with backup: URL) throws {
        let manager = FileManager.default
        let incoming = layout.root.appendingPathComponent("store.restoring", isDirectory: true)
        try? manager.removeItem(at: incoming)
        try manager.copyItem(at: backup, to: incoming)
        try? manager.removeItem(at: layout.store)
        guard rename(incoming.path, layout.store.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: - Yedek

    /// Sağlam halin kopyası. Açılışta (doğrulanmış hal) ve oturumda saatte bir.
    /// Yedek alınamaması kaydı durdurmaz; yalnızca yedek eksik kalır.
    private func backUpIfDueLocked(force: Bool) {
        let now = clock()
        if !force, let lastBackup, now.timeIntervalSince(lastBackup) < Self.backupInterval { return }
        guard FileManager.default.fileExists(atPath: layout.manifest.path) else { return }
        let target = uniqueDirectory(in: layout.backups)
        do {
            try ensureDirectory(layout.backups)
            try FileManager.default.copyItem(at: layout.store, to: target)
            // Yedekte süren işlem kalıntısı olmasın.
            try? FileManager.default.removeItem(at: target.appendingPathComponent("journal.json"))
            try? FileManager.default.removeItem(at: target.appendingPathComponent("staging"))
            lastBackup = now
        } catch {
            try? FileManager.default.removeItem(at: target)
            return
        }
        let all = backupsNewestFirst()
        for old in all.dropFirst(Self.keptBackups) { try? FileManager.default.removeItem(at: old) }
    }

    /// Yedek dizinleri, en yenisi başta (adlar zaman damgası; sözlük sırası = zaman sırası).
    public func backupsNewestFirst() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.backups.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && !$0.hasSuffix(".json") }.sorted(by: >)
            .map { layout.backups.appendingPathComponent($0, isDirectory: true) }
    }

    private func uniqueDirectory(in parent: URL) -> URL {
        let stamp = Self.stamp(clock())
        var candidate = parent.appendingPathComponent(stamp, isDirectory: true)
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(stamp)-\(attempt)", isDirectory: true)
            attempt += 1
        }
        return candidate
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: - Yardımcılar

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func hasContent(_ url: URL) -> Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty
    }
}

// MARK: - Şema 1'den geçiş

extension WorkspaceStore {
    /// `workspace.json` (şema 1) → şema 2.
    ///
    /// Önce asıl dosyanın yedeği alınır. Yeni yapı `store.migrating`'de kurulur,
    /// okunup kaynakla karşılaştırılır; ancak tutarsa tek `rename` ile `store`
    /// olur. Yarıda kalan geçiş yeniden denendiğinde ara dizin baştan kurulur:
    /// kaynak hep aynı dosya olduğu için kayıt çoğalmaz.
    private func migrateLegacyLocked() throws -> (WorkspaceModel, StoreNotice) {
        let manager = FileManager.default
        let data = try Data(contentsOf: layout.legacyWorkspace)
        let source: WorkspaceModel
        do {
            source = try JSONDecoder().decode(WorkspaceModel.self, from: data)
        } catch {
            // Okunamayan şema 1 dosyası: kopyası alınır, kenara çekilir, boş başlanır.
            let backup = try copyLegacy(named: "workspace.bozuk")
            try manager.removeItem(at: layout.legacyWorkspace)
            committed = nil
            return (WorkspaceModel(schemaVersion: StoreManifest.currentSchema),
                    .legacyUnreadable(backup: backup, reason: error.localizedDescription))
        }

        let backup = try copyLegacy(named: "workspace.v1")
        try? manager.removeItem(at: layout.migrating)
        try ensureDirectory(layout.migrating)
        let files = try Self.encode(source)
        let manifest = StoreManifest(
            schemaVersion: StoreManifest.currentSchema,
            activeEnvironmentID: source.activeEnvironmentID,
            collectionOrder: source.collections.map(\.id),
            files: files.mapValues(AtomicFile.digest)
        )
        for (path, file) in files { try AtomicFile.write(file, to: layout.migrating.appendingPathComponent(path)) }
        try AtomicFile.write(try Self.encoder.encode(manifest), to: layout.migrating.appendingPathComponent("manifest.json"))

        // Doğrulama: diskteki yeni yapı okunur, kaynakla aynı mı.
        guard case .success(let state) = Self.read(layout.migrating) else {
            throw StoreError.migrationVerificationFailed(L10n.t("store.migration.unreadable"))
        }
        if let mismatch = Self.difference(source, state.workspace) {
            throw StoreError.migrationVerificationFailed(mismatch)
        }
        if manager.fileExists(atPath: layout.store.path) {
            // Manifestsiz artık (önceki yarım deneme): karantinaya alınır.
            _ = try quarantineLocked()
            try manager.removeItem(at: layout.store)
        }
        guard rename(layout.migrating.path, layout.store.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        committed = manifest
        // Etkin yapı artık şema 2; asıl dosyanın yedeği alındı.
        try? manager.removeItem(at: layout.legacyWorkspace)
        return (state.workspace, .migrated(backup: backup))
    }

    /// Geçiş tamamlandıktan sonra (rename) kesilip asıl dosya silinemediyse:
    /// yedeği zaten var, kaldırılır; yoksa yedeğe taşınır.
    private func settleLegacyLeftoverLocked() {
        guard FileManager.default.fileExists(atPath: layout.legacyWorkspace.path) else { return }
        if (try? copyLegacy(named: "workspace.v1")) != nil {
            try? FileManager.default.removeItem(at: layout.legacyWorkspace)
        }
    }

    /// Aynı içerikli yedek zaten varsa yenisi alınmaz (tekrarlanan deneme).
    private func copyLegacy(named stem: String) throws -> URL {
        let manager = FileManager.default
        try ensureDirectory(layout.backups)
        let data = try Data(contentsOf: layout.legacyWorkspace)
        let existing = ((try? manager.contentsOfDirectory(atPath: layout.backups.path)) ?? [])
            .filter { $0.hasPrefix(stem) && $0.hasSuffix(".json") }
            .map { layout.backups.appendingPathComponent($0) }
        if let same = existing.first(where: { (try? Data(contentsOf: $0)) == data }) { return same }
        var target = layout.backups.appendingPathComponent("\(stem)-\(Self.stamp(clock())).json")
        var attempt = 2
        while manager.fileExists(atPath: target.path) {
            target = layout.backups.appendingPathComponent("\(stem)-\(Self.stamp(clock()))-\(attempt).json")
            attempt += 1
        }
        try AtomicFile.write(data, to: target)
        return target
    }

    /// İki workspace'in kalıcı içeriği aynı mı; değilse farkın kısa tarifi.
    static func difference(_ a: WorkspaceModel, _ b: WorkspaceModel) -> String? {
        if a.collections.map(\.id) != b.collections.map(\.id) { return "collections" }
        if a.collections.flatMap({ $0.requests.map(\.id) }) != b.collections.flatMap({ $0.requests.map(\.id) }) { return "requests" }
        if a.environments.map(\.id) != b.environments.map(\.id) { return "environments" }
        if a.activeEnvironmentID != b.activeEnvironmentID { return "activeEnvironment" }
        guard let left = try? encode(a), let right = try? encode(b) else { return "encode" }
        return left == right ? nil : "content"
    }
}

/// Şema yükseltmeleri. Şema 1 → 2 dosya yapısının değişimi (`migrateLegacy`);
/// bundan sonraki her sürüm buraya bir adım olarak eklenir.
enum StoreMigrations {
    static func upgrade(_ manifest: inout StoreManifest) {
        // 2 → 3: dosya yapısı aynı; örnekler koleksiyon dosyasının içinden
        // ayrı dosyaya bir sonraki kayıtta taşınır (`attachExamples` ikisini
        // de okur). Manifest'te değişecek alan yok.
        manifest.schemaVersion = max(manifest.schemaVersion, StoreManifest.currentSchema)
    }
}

/// Son kayıttaki dosya içerikleri: değeri aynı olan dosya yeniden encode
/// edilmez ve özetlenmez. Karşılaştırma `==` ile; değişmemiş değer aynı
/// belleği paylaştığı için (String/Array kopyalama-yazma) ucuz. Kayıt kilidi
/// altında kullanılır (`WorkspaceStore.lock`).
///
/// Yanlış içerik yazamaz: aynı değer + aynı encoder = aynı bayt (çıktı
/// sıralı anahtarlı, kararlı). Diskteki hal ne olursa olsun geçerlidir;
/// yazılıp yazılmayacağına yine manifest özeti karar verir.
final class EncodeCache {
    struct Entry {
        let value: Any
        let digest: String
        let encode: () throws -> Data
    }

    private var entries: [String: Entry] = [:]

    /// Değer son kayıttakiyle aynıysa onun özeti.
    func hit<T: Encodable & Equatable>(for value: T, at path: String) -> Entry? {
        guard let cached = entries[path], let old = cached.value as? T, old == value else { return nil }
        return cached
    }

    func store<T: Encodable & Equatable>(_ value: T, digest: String, at path: String) {
        entries[path] = Entry(value: value, digest: digest, encode: { try WorkspaceStore.encoder.encode(value) })
    }

    /// Artık olmayan dosyaların kaydı düşer (silinen istek/koleksiyon).
    func retain(only paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }
}
