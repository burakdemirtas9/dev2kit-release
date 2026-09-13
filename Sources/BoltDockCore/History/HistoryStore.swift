import Foundation

/// İstek geçmişini şifreli olarak saklar.
///
/// Kayıtlar düz metin JSON'a yazılmaz: geçmiş, gönderilen istek ve alınan
/// yanıtın izini taşıdığı için vault kadar hassastır.
public final class HistoryStore: @unchecked Sendable {
    private let file: EncryptedJSONFile<[HistoryEntry]>
    private let lock = NSLock()
    /// Diskteki kayıtlar bellekte tutulur; her gönderimde dosyayı baştan
    /// okumak gereksiz I/O olurdu.
    private var cache: [HistoryEntry]?

    public init(directory: URL? = nil) {
        let dir = directory ?? AppPaths.supportDirectory
        self.file = EncryptedJSONFile(
            fileURL: dir.appendingPathComponent("history.enc"),
            keyURL: dir.appendingPathComponent(".history.key")
        )
    }

    /// Tüm kayıtlar, en yenisi başta.
    public func entries() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Kaydı ekler ve saklama sınırlarını uygular.
    @discardableResult
    public func append(_ entry: HistoryEntry, settings: HistorySettings) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        guard settings.isEnabled else { return loadLocked() }
        var all = loadLocked()
        all.insert(entry, at: 0)
        all = Self.prune(all, settings: settings, now: Date())
        persistLocked(all)
        return all
    }

    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        cache = []
        try? file.deleteFile()
    }

    /// Yalnızca belirli bir environment'ın kayıtlarını siler
    /// (ör. prod geçmişini temizlemek).
    public func deleteEntries(environmentName: String?) {
        lock.lock(); defer { lock.unlock() }
        let remaining = loadLocked().filter { $0.environmentName != environmentName }
        persistLocked(remaining)
    }

    public func delete(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        persistLocked(loadLocked().filter { $0.id != id })
    }

    /// Saklama kuralları: adet sınırı ve yaş sınırı; hangisi önce dolarsa.
    static func prune(_ entries: [HistoryEntry], settings: HistorySettings, now: Date) -> [HistoryEntry] {
        let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86_400)
        return entries
            .sorted { $0.date > $1.date }
            .filter { $0.date >= cutoff }
            .prefix(settings.retentionCount)
            .map { $0 }
    }

    // MARK: - Kilit altında çağrılır

    private func loadLocked() -> [HistoryEntry] {
        if let cache { return cache }
        // Bozuk ya da okunamayan dosya geçmişi kaybettirir ama uygulamayı
        // engellememeli; boş listeyle devam edilir.
        let loaded = (try? file.load(fallback: [])) ?? []
        cache = loaded
        return loaded
    }

    private func persistLocked(_ entries: [HistoryEntry]) {
        cache = entries
        try? file.save(entries)
    }
}
