import Foundation

/// Kurum collection'larının workspace'e yerleşmesi ve korunması (tek kural kaynağı).
///
/// Kurum collection'ları `workspace.collections` içinde durur (istek editörü,
/// sekmeler, gönderme olduğu gibi çalışır). Collection'ı değiştiren onlarca yol
/// (editör, sürükle-bırak, örnek kaydetme, yeniden adlandırma, silme…) tek tek
/// korunmaz: workspace her değiştiğinde `enforce` eski ile yeniyi karşılaştırır.
public enum TeamSync {
    public struct Enforced: Equatable, Sendable {
        public var collections: [CollectionModel]
        /// Salt okunur bir kurum collection'ına dokunuldu ve geri alındı.
        public var blocked: Bool
        /// Düzenleme yetkisi olan ve değişen kurum collection'ları (kaydedilmedi).
        public var dirtied: Set<UUID>
        /// Yalnızca yanıt örnekleri değişen kurum collection'ları: örnekler
        /// yereldir (sunucuya gitmez), kirletmez ama önbelleğe yazılmalı.
        public var localChanged: Set<UUID> = []
    }

    /// - Düzenlenemeyen kurum collection'ı değiştiyse ya da kaybolduysa eski hali
    ///   geri konur; içinden başka collection'a taşınan istekler oradan çıkarılır
    ///   (taşıma kopyaya dönüşmez, kimlik çakışmaz).
    /// - Düzenlenebilen değiştiyse `dirtied`'a girer. Silinmesi yalnızca katalogdan
    ///   önce çıkarılarak (sunucuda silindikten sonra) olur.
    /// - Yalnızca yanıt örnekleri değiştiyse (salt okunur olsa da) serbesttir:
    ///   örnekler bu Mac'te kalır, `localChanged`'e girer.
    public static func enforce(old: [CollectionModel], new: [CollectionModel], catalog: TeamCatalog) -> Enforced {
        guard !catalog.entries.isEmpty else { return Enforced(collections: new, blocked: false, dirtied: []) }
        var result = new
        var blocked = false
        var dirtied: Set<UUID> = []
        var localChanged: Set<UUID> = []
        let newByID = Dictionary(new.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for (oldIndex, previous) in old.enumerated() where catalog.isTeam(previous.id) {
            let current = newByID[previous.id].map { new[$0] }
            if current == previous { continue }
            if let current, withoutExamples(current) == withoutExamples(previous) {
                localChanged.insert(current.id)
                continue
            }
            if let current, catalog.canEdit(previous.id) {
                dirtied.insert(current.id)
                continue
            }
            blocked = true
            let protectedIDs = Set(previous.requests.map(\.id))
            for index in result.indices where result[index].id != previous.id {
                result[index].requests.removeAll { protectedIDs.contains($0.id) }
            }
            if let index = result.firstIndex(where: { $0.id == previous.id }) {
                result[index] = previous
            } else {
                result.insert(previous, at: min(oldIndex, result.count))
            }
        }
        // Salt okunur collection'ın isteği başka bir collection'a kopya kimlikle
        // giremez. Çok adımlı değişiklikte (önce çıkar, sonra ekle) ilk adım
        // geri alınınca ikinci adım yalnızca hedefi değiştirir; yukarıdaki
        // karşılaştırma bunu görmez.
        let readOnlyIDs = Set(result.filter { catalog.isTeam($0.id) && !catalog.canEdit($0.id) }.flatMap { $0.requests.map(\.id) })
        if !readOnlyIDs.isEmpty {
            for index in result.indices where !catalog.isTeam(result[index].id) {
                let before = result[index].requests.count
                result[index].requests.removeAll { readOnlyIDs.contains($0.id) }
                if result[index].requests.count != before { blocked = true }
            }
        }
        return Enforced(collections: result, blocked: blocked, dirtied: dirtied, localChanged: localChanged)
    }

    /// Listeyi (`GET /collections`) workspace'e yerleştirir. Sürümü değişmeyen
    /// ve içeriği çekilmiş collection korunur; değişen (kaydedilmemiş değişikliği
    /// yoksa) yeniden çekilmek üzere işaretlenir; sunucuda olmayanlar çıkar.
    /// Kurum collection'ları kendi collection'larının önünde, kendi ekibi önce.
    ///
    /// Kaydedilmemiş değişikliği olan collection sunucuda değiştiyse yerel çalışma
    /// ezilmez ve `remoteChanged`'e girer (kullanıcıya sorulur). Yerel kayıt
    /// düzenlemenin dayandığı ESKİ sürümü tutar: sorulmadan kaydedilirse sunucu
    /// 409 döner, başkasının değişikliği sessizce ezilmez.
    public static func merge(_ summaries: [TeamCollectionSummary], into collections: [CollectionModel],
                             catalog: TeamCatalog, ownGroup: String?)
        -> (collections: [CollectionModel], catalog: TeamCatalog, remoteChanged: [UUID]) {
        var nextCatalog = TeamCatalog()
        var remoteChanged: [UUID] = []
        var team: [CollectionModel] = []
        let existing = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = summaries.sorted { lhs, rhs in
            let lhsOwn = lhs.ownerGroup == ownGroup, rhsOwn = rhs.ownerGroup == ownGroup
            if lhsOwn != rhsOwn { return lhsOwn }
            if lhs.ownerGroup != rhs.ownerGroup { return lhs.ownerGroup < rhs.ownerGroup }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        for summary in ordered {
            let id = TeamCollectionCodec.stableID(summary.id, "collection")
            var info = catalog.entries[id] ?? TeamCollectionInfo(summary: summary)
            var collection = existing[id] ?? CollectionModel(id: id, name: summary.name, requests: [])
            let versionChanged = info.summary.version != summary.version
            if info.isDirty {
                if versionChanged { remoteChanged.append(id) }
                info.summary = summary.withVersion(info.summary.version)
                // Kaydedilmemiş değişiklik ancak çekilmiş içerikte oluşur:
                // çevrimdışı açılışta salt okunura alınan (`isLoaded = false`)
                // kirli collection, liste yeniden alınınca düzenlenmeye döner.
                // Yoksa yeniden çekilmez (kirli) ve salt okunur kalırdı.
                info.isLoaded = true
            } else {
                if versionChanged { info.isLoaded = false }
                collection.name = summary.name
                info.summary = summary
            }
            nextCatalog.entries[id] = info
            team.append(collection)
        }
        let mine = collections.filter { !catalog.isTeam($0.id) && !nextCatalog.isTeam($0.id) }
        return (team + mine, nextCatalog, remoteChanged)
    }

    /// Yenilemeden sonra içeriği sunucudan çekilecek collection'lar (liste sırasıyla).
    /// - İçeriği eskimiş/çekilmemiş olan: görünüyorsa (açık) ya da daha önce
    ///   çekilmişse. Hiç çekilmemiş kapalı collection açılınca çekilir.
    /// - `reloadLoaded` (kullanıcı Yenile'ye bastı): çekilmiş olanların hepsi,
    ///   sürümü aynı görünse de.
    /// Kaydedilmemiş değişikliği olan hiçbir zaman listede olmaz.
    public static func reloadTargets(order: [UUID], catalog: TeamCatalog, previouslyLoaded: Set<UUID>,
                                     collapsed: Set<UUID>, reloadLoaded: Bool) -> [UUID] {
        order.filter { id in
            guard let info = catalog.entries[id], !info.isDirty else { return false }
            if info.isLoaded { return reloadLoaded }
            return previouslyLoaded.contains(id) || !collapsed.contains(id)
        }
    }

    /// Çekilen içeriği yerleştirir: sürüm ve izinler güncellenir, kaydedilmemiş
    /// değişiklik silinir (çağıran yeniden yükleme kararı vermiştir). Yanıt
    /// örnekleri sunucudan gelmez; yerel örnekler istek kimliğine göre korunur
    /// (yoksa her yenileme ve kayıt onları silerdi).
    public static func apply(_ detail: TeamCollectionDetail, to collections: [CollectionModel],
                             catalog: TeamCatalog) throws -> (collections: [CollectionModel], catalog: TeamCatalog, skipped: Int) {
        let decoded = try TeamCollectionCodec.decode(detail.content, remoteID: detail.summary.id, name: detail.summary.name)
        let id = decoded.collection.id
        let used = Set(collections.filter { $0.id != id }.flatMap { $0.requests.map(\.id) })
        var collection = TeamCollectionCodec.resolvingCollisions(decoded.collection, used: used, remoteID: detail.summary.id)
        var next = collections
        if let index = next.firstIndex(where: { $0.id == id }) {
            keepExamples(of: next[index], in: &collection)
            next[index] = collection
        } else {
            next.insert(collection, at: 0)
        }
        var nextCatalog = catalog
        nextCatalog.entries[id] = TeamCollectionInfo(summary: detail.summary, isLoaded: true, isDirty: false,
                                                     skippedRequests: decoded.skippedRequests)
        return (next, nextCatalog, decoded.skippedRequests)
    }

    /// Kurum belgesinde örnek yoktur; karşılaştırma ve kayıt bu hale göre.
    public static func withoutExamples(_ collection: CollectionModel) -> CollectionModel {
        guard collection.requests.contains(where: { !$0.examples.isEmpty }) else { return collection }
        var copy = collection
        for index in copy.requests.indices { copy.requests[index].examples = [] }
        return copy
    }

    private static func keepExamples(of previous: CollectionModel, in collection: inout CollectionModel) {
        let kept = Dictionary(previous.requests.filter { !$0.examples.isEmpty }.map { ($0.id, $0.examples) },
                              uniquingKeysWith: { first, _ in first })
        guard !kept.isEmpty else { return }
        for index in collection.requests.indices {
            if let examples = kept[collection.requests[index].id] { collection.requests[index].examples = examples }
        }
    }

    /// Atılmak üzere olan kurum collection'larından kaydedilmemiş değişikliği
    /// olanların kopyaları: yeni kimlikler, çakışmayan ad (`ad <suffix>`).
    /// Çağıran bunları kendi collection'larına ekler. Oturum bitişi, çıkış ve
    /// sunucuda silinme yerel çalışmayı sessizce götürmesin diye.
    public static func rescueCopies(dropping ids: Set<UUID>, from collections: [CollectionModel],
                                    catalog: TeamCatalog, suffix: String) -> [CollectionModel] {
        var names = collections.map(\.name)
        return collections.filter { ids.contains($0.id) && catalog.entries[$0.id]?.isDirty == true }.map { collection in
            let name = CollectionPorting.uniqueName(collection.name, suffix: suffix, existingNames: names)
            names.append(name)
            return CollectionPorting.copyWithNewIDs(collection, name: name)
        }
    }
}

/// Kurum önbelleği: `<veri>/team/cache.json` (0600, atomik, yedek dışı). Son
/// çekilen liste ve içerikler; açılışta oturum doğrulanana kadar salt okunur
/// gösterilir. Sunucuya kaydedilmemiş düzenlemeler de burada durur (workspace
/// kaydına girmezler): uygulama kapanıp açılınca kaldıkları yerden sürer.
/// Çıkışta ve oturum bitince silinir. Token içermez.
public struct TeamCache: Codable, Equatable, Sendable {
    public var identity: TeamIdentity
    public var canCreate: Bool
    public var catalog: TeamCatalog
    public var collections: [CollectionModel]

    public init(identity: TeamIdentity, canCreate: Bool, catalog: TeamCatalog, collections: [CollectionModel]) {
        self.identity = identity
        self.canCreate = canCreate
        self.catalog = catalog
        self.collections = collections
    }

    public static func url(root: URL) -> URL {
        root.appendingPathComponent("team", isDirectory: true).appendingPathComponent("cache.json")
    }

    public static func load(root: URL) -> TeamCache? {
        guard let data = try? Data(contentsOf: url(root: root)) else { return nil }
        return try? JSONDecoder().decode(TeamCache.self, from: data)
    }

    public func save(root: URL) throws {
        try AtomicFile.write(try JSONEncoder().encode(self), to: Self.url(root: root), excludedFromBackup: true)
    }

    public static func delete(root: URL) {
        try? FileManager.default.removeItem(at: url(root: root))
    }
}
