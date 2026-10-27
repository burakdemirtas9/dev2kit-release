import Foundation

/// İstek geçmişi: şifreli dizin + kayıt başına şifreli içerik dosyası.
///
/// ```
/// <kök>/history/index.enc        liste: tarih, durum, adres, gövdesiz anlık görüntü
/// <kök>/history/index.prev.enc   bir önceki sağlam dizin (yedek)
/// <kök>/history/bodies/<id>.enc  yanıt önizlemesi + istek gövdesi
/// <kök>/.history.key             anahtar (0600); Developer ID'li sürümde Keychain
/// ```
/// Neden ayrı: eskiden tek `history.enc` her gönderimde baştan yazılıyor ve
/// liste açılınca tüm yanıt önizlemeleri (kayıt başına 20.000 karaktere
/// kadar) belleğe alınıyordu. Liste artık yalnızca dizini okur; içerik kayıt
/// açılınca (`fullEntry`) yüklenir.
///
/// Sıra: önce içerik dosyası, sonra dizin. Arada kesilirse geriye sahipsiz
/// içerik kalır (sonraki açılışta silinir); dizin hiçbir zaman olmayan bir
/// dosyayı göstermez. Yazımlar seri kuyrukta, arayüzü bekletmez.
///
/// Kayıtlar düz metin yazılmaz: geçmiş, gönderilen istek ve alınan yanıtın
/// izini taşıdığı için vault kadar hassastır.
public final class HistoryStore: @unchecked Sendable {
    struct IndexRecord: Codable, Equatable {
        /// İçeriği çıkarılmış kayıt (önizleme yok, anlık görüntünün gövdesi yok).
        var entry: HistoryEntry
        /// İçerik dosyasının boyutu; 0 = içerik yok.
        var payloadBytes: Int
    }

    struct Payload: Codable {
        var responsePreview: String?
        var body: RequestBody
    }

    private let root: URL
    private let directory: URL
    private let key: EncryptionKeySource
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var records: [IndexRecord]?
    /// Okunamayan dizin kenara alındıysa yeri (kullanıcıya söylenir).
    public private(set) var recoveryNotice: URL?
    /// Şifreli geçmiş var ama anahtarı alınamadıysa nedeni. O oturumda
    /// geçmiş boş görünür ve hiç yazılmaz; dosyalara dokunulmaz.
    public private(set) var keyFailure: Error?

    /// `key` verilmezse anahtar `<kök>/.history.key` dosyasındadır.
    /// Developer ID'li sürümde Keychain'deki anahtar verilir (bkz. `HistoryKeyMigration`).
    public init(directory: URL? = nil, key: SecretStoreKey? = nil, queue: DispatchQueue? = nil) {
        let base = directory ?? AppPaths.supportDirectory
        self.root = base
        self.directory = base.appendingPathComponent("history", isDirectory: true)
        self.key = key.map(EncryptionKeySource.stored) ?? .file(base.appendingPathComponent(HistoryKeyMigration.fileName))
        self.queue = queue ?? DispatchQueue(label: "com.dev2kit.history", qos: .utility)
    }

    private var indexFile: EncryptedJSONFile<[IndexRecord]> {
        EncryptedJSONFile(fileURL: directory.appendingPathComponent("index.enc"), key: key)
    }
    private var previousIndexFile: EncryptedJSONFile<[IndexRecord]> {
        EncryptedJSONFile(fileURL: directory.appendingPathComponent("index.prev.enc"), key: key)
    }
    private var bodies: URL { directory.appendingPathComponent("bodies", isDirectory: true) }
    private func payloadFile(_ id: UUID) -> EncryptedJSONFile<Payload> {
        EncryptedJSONFile(fileURL: bodies.appendingPathComponent("\(id.uuidString).enc"), key: key)
    }
    /// Şema 1'in tek dosyası.
    private var legacyFile: EncryptedJSONFile<[HistoryEntry]> {
        EncryptedJSONFile(fileURL: root.appendingPathComponent("history.enc"), key: key)
    }

    // MARK: - Okuma

    /// Tüm kayıtlar (içeriksiz), en yenisi başta. Liste için.
    public func entries() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().map(\.entry)
    }

    /// Kaydın tamamı: yanıt önizlemesi ve istek gövdesi dahil. İçerik
    /// dosyası okunamazsa içeriksiz kayıt döner.
    public func fullEntry(id: UUID) -> HistoryEntry? {
        let record: IndexRecord?
        lock.lock()
        record = loadLocked().first { $0.entry.id == id }
        lock.unlock()
        guard let record else { return nil }
        guard record.payloadBytes > 0, let payload = try? payloadFile(id).load(fallback: Payload(responsePreview: nil, body: .none)) else {
            return record.entry
        }
        return Self.merge(record.entry, payload)
    }

    // MARK: - Yazma

    /// Kaydı ekler, saklama sınırlarını uygular ve güncel listeyi döner.
    /// Disk yazımı arka planda.
    @discardableResult
    public func append(_ entry: HistoryEntry, settings: HistorySettings) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        let current = loadLocked()
        guard settings.isEnabled, keyFailure == nil else { return current.map(\.entry) }
        let (stripped, payload) = Self.split(entry)
        let encodedPayload = payload.flatMap { try? JSONEncoder().encode($0) }
        var all = current
        all.insert(IndexRecord(entry: stripped, payloadBytes: encodedPayload?.count ?? 0), at: 0)
        let kept = Self.prune(all, settings: settings, now: Date())
        let dropped = Set(all.map(\.entry.id)).subtracting(kept.map(\.entry.id))
        records = kept
        enqueueWrite(index: kept, payload: payload.map { (entry.id, $0) }, deleting: dropped)
        return kept.map(\.entry)
    }

    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        records = []
        queue.async { [directory] in
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Yalnızca belirli bir environment'ın kayıtlarını siler
    /// (ör. prod geçmişini temizlemek).
    public func deleteEntries(environmentName: String?) {
        remove { $0.entry.environmentName == environmentName }
    }

    public func delete(id: UUID) {
        remove { $0.entry.id == id }
    }

    /// Bekleyen yazımlar bitene kadar bekler (kapanış, testler).
    public func waitForPendingWrites() { queue.sync {} }

    /// Diskteki geçmişin toplam boyutu (arayüzde göstermek için).
    public func fileSizeBytes() -> Int {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    // MARK: - Saklama kuralları

    /// Yaş, adet ve toplam boyut; hangisi önce dolarsa. Boyuta içerik
    /// dosyaları da sayılır.
    static func prune(_ records: [IndexRecord], settings: HistorySettings, now: Date) -> [IndexRecord] {
        let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86_400)
        let byAgeAndCount = records
            .sorted { $0.entry.date > $1.entry.date }
            .filter { $0.entry.date >= cutoff }
            .prefix(settings.retentionCount)
        guard settings.maxTotalBytes > 0 else { return Array(byAgeAndCount) }
        let encoder = JSONEncoder()
        var kept: [IndexRecord] = []
        var total = 0
        for record in byAgeAndCount {
            let size = ((try? encoder.encode(record).count) ?? 0) + record.payloadBytes
            // En yeni kayıt tek başına bütçeyi aşsa bile tutulur.
            if !kept.isEmpty, total + size > settings.maxTotalBytes { break }
            kept.append(record)
            total += size
        }
        return kept
    }

    /// Eski API (testler, ayar ekranındaki hesap): kayıt listesine uygular.
    static func prune(_ entries: [HistoryEntry], settings: HistorySettings, now: Date) -> [HistoryEntry] {
        prune(entries.map { entry -> IndexRecord in
            let (stripped, payload) = split(entry)
            return IndexRecord(entry: stripped, payloadBytes: payload.flatMap { try? JSONEncoder().encode($0).count } ?? 0)
        }, settings: settings, now: now).map(\.entry)
    }

    // MARK: - Kayıt ↔ dizin + içerik

    static func split(_ entry: HistoryEntry) -> (HistoryEntry, Payload?) {
        var snapshot = entry.snapshot
        let body = snapshot.body
        snapshot.body = .none
        let stripped = HistoryEntry(
            id: entry.id, date: entry.date, requestID: entry.requestID, requestName: entry.requestName,
            collectionName: entry.collectionName, environmentName: entry.environmentName,
            method: entry.method, url: entry.url, outcome: entry.outcome, snapshot: snapshot, responsePreview: nil
        )
        let hasPayload = entry.responsePreview != nil || body != .none
        return (stripped, hasPayload ? Payload(responsePreview: entry.responsePreview, body: body) : nil)
    }

    static func merge(_ entry: HistoryEntry, _ payload: Payload) -> HistoryEntry {
        var snapshot = entry.snapshot
        snapshot.body = payload.body
        return HistoryEntry(
            id: entry.id, date: entry.date, requestID: entry.requestID, requestName: entry.requestName,
            collectionName: entry.collectionName, environmentName: entry.environmentName,
            method: entry.method, url: entry.url, outcome: entry.outcome, snapshot: snapshot,
            responsePreview: payload.responsePreview
        )
    }

    // MARK: - Kilit altında

    private func remove(where predicate: (IndexRecord) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        let all = loadLocked()
        guard keyFailure == nil else { return }
        let removed = Set(all.filter(predicate).map(\.entry.id))
        guard !removed.isEmpty else { return }
        let kept = all.filter { !removed.contains($0.entry.id) }
        records = kept
        enqueueWrite(index: kept, payload: nil, deleting: removed)
    }

    /// İçerik → dizin (önceki dizin yedeğe) → düşen içerikler silinir.
    private func enqueueWrite(index: [IndexRecord], payload: (UUID, Payload)?, deleting: Set<UUID>) {
        queue.async { [self] in
            if let (id, content) = payload {
                // İçerik yazılamazsa (disk dolu) dizine içeriksiz girer: liste
                // olmayan dosyayı göstermesin.
                if (try? payloadFile(id).save(content)) == nil {
                    lock.lock()
                    if let position = records?.firstIndex(where: { $0.entry.id == id }) { records?[position].payloadBytes = 0 }
                    let current = records ?? index
                    lock.unlock()
                    writeIndex(current)
                    return
                }
            }
            writeIndex(index)
            for id in deleting { try? FileManager.default.removeItem(at: bodies.appendingPathComponent("\(id.uuidString).enc")) }
        }
    }

    private func writeIndex(_ index: [IndexRecord]) {
        let manager = FileManager.default
        let current = directory.appendingPathComponent("index.enc")
        let previous = directory.appendingPathComponent("index.prev.enc")
        // Bir önceki sağlam dizin yedekte kalır (bozulursa dönülür).
        if manager.fileExists(atPath: current.path), (try? indexFile.load(fallback: [])) != nil {
            try? manager.removeItem(at: previous)
            try? manager.copyItem(at: current, to: previous)
        }
        try? indexFile.save(index)
    }

    private func loadLocked() -> [IndexRecord] {
        if let records { return records }
        let manager = FileManager.default
        // Anahtar gelmiyorsa (Keychain kilitli/erişilemez, anahtar dosyası
        // okunamıyor ya da yok) veri bozuk SAYILMAZ: kenara alınmaz ve bu
        // oturumda yazılmaz. Yazılsaydı, anahtar sonradan gelince yeni dizin
        // eskisinin üzerine geçerdi.
        do {
            if manager.fileExists(atPath: directory.appendingPathComponent("index.enc").path) {
                try indexFile.requireKey()
            } else if manager.fileExists(atPath: root.appendingPathComponent("history.enc").path) {
                try legacyFile.requireKey()
            }
        } catch {
            keyFailure = error
            records = []
            return []
        }
        var loaded: [IndexRecord]
        var cleanLoad = true
        if manager.fileExists(atPath: directory.appendingPathComponent("index.enc").path) {
            do {
                loaded = try indexFile.load(fallback: [])
            } catch {
                // Okunamayan dizin silinmez, kenara alınır; önceki sağlam dizine dönülür.
                cleanLoad = false
                recoveryNotice = setAside(directory.appendingPathComponent("index.enc"))
                loaded = (try? previousIndexFile.load(fallback: [])) ?? []
            }
        } else if manager.fileExists(atPath: root.appendingPathComponent("history.enc").path) {
            loaded = migrateLegacyLocked()
        } else {
            loaded = []
        }
        records = loaded
        if cleanLoad { removeOrphans(referenced: Set(loaded.map(\.entry.id))) }
        return loaded
    }

    /// Dizinin göstermediği içerik dosyaları (yarıda kalan yazım, silinmiş kayıt).
    /// Yalnızca dizin sorunsuz okunduysa: kenara alınmış dizinin içeriği silinmesin.
    private func removeOrphans(referenced: Set<UUID>) {
        queue.async { [bodies] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: bodies.path)) ?? []
            for name in names {
                let stem = (name as NSString).deletingPathExtension
                if let id = UUID(uuidString: stem), referenced.contains(id) { continue }
                try? FileManager.default.removeItem(at: bodies.appendingPathComponent(name))
            }
        }
    }

    /// Şema 1 `history.enc` → dizin + içerikler. Eski dosya `history.v1.enc`
    /// olarak kalır (yedek); okunamazsa kenara alınır, boş başlanır.
    private func migrateLegacyLocked() -> [IndexRecord] {
        let legacyURL = root.appendingPathComponent("history.enc")
        guard let legacy = try? legacyFile.load(fallback: []) else {
            recoveryNotice = setAside(legacyURL)
            return []
        }
        var result: [IndexRecord] = []
        for entry in legacy {
            let (stripped, payload) = Self.split(entry)
            var bytes = 0
            if let payload, (try? payloadFile(entry.id).save(payload)) != nil {
                bytes = (try? JSONEncoder().encode(payload).count) ?? 0
            }
            result.append(IndexRecord(entry: stripped, payloadBytes: bytes))
        }
        do {
            try indexFile.save(result)
            // Doğrulama: yeni dizin okunuyor ve kayıt sayısı tutuyor.
            guard try indexFile.load(fallback: []).count == legacy.count else { return result }
            let backup = root.appendingPathComponent("history.v1.enc")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: legacyURL, to: backup)
        } catch {
            // Eski dosya yerinde kalır; sonraki açılışta yeniden denenir
            // (aynı kimlikler: kayıt çoğalmaz).
        }
        return result
    }

    /// Dosyayı aynı dizinde `.<ad>.bozuk-<zaman>` adıyla kenara alır.
    private func setAside(_ url: URL) -> URL? {
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).bozuk-\(WorkspaceStore.stamp(Date()))")
        return (try? FileManager.default.moveItem(at: url, to: target)) != nil ? target : nil
    }
}
