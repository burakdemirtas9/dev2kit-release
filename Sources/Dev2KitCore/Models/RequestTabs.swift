import Foundation

/// Açık istek sekmelerinin durumu (Postman benzeri).
///
/// Önizleme sekmesi geçicidir: yeni bir istek açılınca onun yerini alır.
/// İstek kullanılınca (düzenleme, gönderme, çift tıklama) `keep` ile kalıcı olur.
/// Seçim burada tutulmaz; kapatma işlemleri seçilmesi gereken sekmeyi döner.
///
/// Sabitleme (2026-10-31, Chrome / VS Code kuralları): sabitlenen sekmeler
/// her zaman başta ve sabitlenme sırasıyla durur; "Diğerlerini Kapat" ve
/// "Sağdakileri Kapat" onları kapatmaz; sürükleme yalnızca kendi grubu
/// içinde; sabitleme kalkınca sekme sabit olmayanların başına geçer.
/// Kapatma (⌘W dahil) sabit sekmeyi de kapatır (kullanıcı kararı).
///
/// Değişmez: `tabs` = `pinned` (aynı sırayla) + sabit olmayanlar; önizleme
/// hiçbir zaman sabit değildir.
public struct RequestTabs: Equatable, Sendable {
    public private(set) var tabs: [UUID]
    public private(set) var preview: UUID?
    /// Sabitlenmiş sekmeler, sabitlenme sırasıyla (`tabs`'ın başı).
    public private(set) var pinned: [UUID]

    /// Kayıttan gelen değerler normalize edilir: tekrarlar atılır, açık
    /// olmayan sabitler düşer, sabitler başa alınır, sabit önizleme olmaz.
    public init(tabs: [UUID] = [], preview: UUID? = nil, pinned: [UUID] = []) {
        var seen = Set<UUID>()
        let open = tabs.filter { seen.insert($0).inserted }
        var seenPins = Set<UUID>()
        let pins = pinned.filter { seen.contains($0) && seenPins.insert($0).inserted }
        self.pinned = pins
        self.tabs = pins + open.filter { !seenPins.contains($0) }
        self.preview = preview.flatMap { seen.contains($0) && !seenPins.contains($0) ? $0 : nil }
    }

    /// Kalıcı sekmeler (bir sonraki açılışa taşınanlar).
    public var permanent: [UUID] { tabs.filter { $0 != preview } }

    public func isPinned(_ id: UUID) -> Bool { pinned.contains(id) }

    /// Açık değilse önizleme olarak açar: varsa mevcut önizlemenin yerine geçer.
    /// Önizleme sabit olmadığı için bu hep sabit olmayan bölgede kalır.
    public mutating func open(_ id: UUID) {
        guard !tabs.contains(id) else { return }
        if let preview, let index = tabs.firstIndex(of: preview) {
            tabs[index] = id
        } else {
            tabs.append(id)
        }
        preview = id
    }

    /// Kalıcı yapar; açık değilse kalıcı olarak açar.
    public mutating func keep(_ id: UUID) {
        if !tabs.contains(id) { tabs.append(id) }
        if preview == id { preview = nil }
    }

    /// Sabitler: açık değilse açar, kalıcı yapar, sabitlerin sonuna taşır.
    public mutating func pin(_ id: UUID) {
        keep(id)
        guard !pinned.contains(id) else { return }
        tabs.removeAll { $0 == id }
        tabs.insert(id, at: pinned.count)
        pinned.append(id)
    }

    /// Sabitlemeyi kaldırır: sekme sabit olmayanların başına geçer.
    public mutating func unpin(_ id: UUID) {
        guard let index = pinned.firstIndex(of: id) else { return }
        pinned.remove(at: index)
        tabs.removeAll { $0 == id }
        tabs.insert(id, at: pinned.count)
    }

    /// Kapatır (sabit olsa da). Kapatılan seçiliyse yerine seçilecek sekmeyi
    /// döner: önce sağdaki, yoksa soldaki; hiç sekme kalmadıysa nil.
    public mutating func close(_ id: UUID, selected: UUID?) -> UUID? {
        guard let index = tabs.firstIndex(of: id) else { return selected }
        tabs.remove(at: index)
        pinned.removeAll { $0 == id }
        if preview == id { preview = nil }
        guard selected == id else { return selected }
        return tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
    }

    /// Verilen sekme ve sabitler dışındakileri kapatır.
    public mutating func closeOthers(keeping id: UUID) -> UUID? {
        guard tabs.contains(id) else { return tabs.first }
        let kept = Set(pinned).union([id])
        tabs.removeAll { !kept.contains($0) }
        if let preview, !kept.contains(preview) { self.preview = nil }
        return id
    }

    /// Sağdaki sabit olmayan sekmeleri kapatır.
    public mutating func closeToRight(of id: UUID, selected: UUID?) -> UUID? {
        guard let index = tabs.firstIndex(of: id) else { return selected }
        let closing = Set(tabs[(index + 1)...].filter { !pinned.contains($0) })
        tabs.removeAll { closing.contains($0) }
        if let preview, closing.contains(preview) { self.preview = nil }
        if let selected, closing.contains(selected) { return id }
        return selected
    }

    /// Sürükle-bırak: sekmeyi hedefin konumuna taşır. Yalnızca aynı grup
    /// içinde (sabit ↔ sabit, sabit olmayan ↔ sabit olmayan); grup sınırını
    /// aşan taşıma yok sayılır.
    public mutating func move(_ id: UUID, before target: UUID) {
        guard id != target,
              isPinned(id) == isPinned(target),
              let from = tabs.firstIndex(of: id),
              let to = tabs.firstIndex(of: target) else { return }
        tabs.remove(at: from)
        tabs.insert(id, at: to)
        pinned = Array(tabs.prefix(pinned.count))
    }

    /// Sonraki/önceki sekme; uçlarda başa sarar.
    public func adjacent(to selected: UUID?, offset: Int) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        let current = selected.flatMap { tabs.firstIndex(of: $0) } ?? 0
        return tabs[((current + offset) % tabs.count + tabs.count) % tabs.count]
    }

    /// Artık var olmayan isteklerin sekmelerini kapatır; seçimi günceller.
    public mutating func prune(keeping live: Set<UUID>, selected: UUID?) -> UUID? {
        var selection = selected
        for id in tabs where !live.contains(id) {
            selection = close(id, selected: selection)
        }
        return selection
    }
}
