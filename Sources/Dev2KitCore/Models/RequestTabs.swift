import Foundation

/// Açık istek sekmelerinin durumu (Postman benzeri).
///
/// Önizleme sekmesi geçicidir: yeni bir istek açılınca onun yerini alır.
/// İstek kullanılınca (düzenleme, gönderme, çift tıklama) `pin` ile kalıcı olur.
/// Seçim burada tutulmaz; kapatma işlemleri seçilmesi gereken sekmeyi döner.
public struct RequestTabs: Equatable, Sendable {
    public private(set) var tabs: [UUID]
    public private(set) var preview: UUID?

    public init(tabs: [UUID] = [], preview: UUID? = nil) {
        self.tabs = tabs
        self.preview = preview.flatMap { tabs.contains($0) ? $0 : nil }
    }

    /// Kalıcı sekmeler (bir sonraki açılışa taşınanlar).
    public var permanent: [UUID] { tabs.filter { $0 != preview } }

    /// Açık değilse önizleme olarak açar: varsa mevcut önizlemenin yerine geçer.
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
    public mutating func pin(_ id: UUID) {
        if !tabs.contains(id) { tabs.append(id) }
        if preview == id { preview = nil }
    }

    /// Kapatır. Kapatılan seçiliyse yerine seçilecek sekmeyi döner: önce sağdaki,
    /// yoksa soldaki; hiç sekme kalmadıysa nil.
    public mutating func close(_ id: UUID, selected: UUID?) -> UUID? {
        guard let index = tabs.firstIndex(of: id) else { return selected }
        tabs.remove(at: index)
        if preview == id { preview = nil }
        guard selected == id else { return selected }
        return tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
    }

    public mutating func closeOthers(keeping id: UUID) -> UUID? {
        guard tabs.contains(id) else { return tabs.first }
        tabs = [id]
        if preview != id { preview = nil }
        return id
    }

    public mutating func closeToRight(of id: UUID, selected: UUID?) -> UUID? {
        guard let index = tabs.firstIndex(of: id) else { return selected }
        let closing = Set(tabs[(index + 1)...])
        tabs.removeAll { closing.contains($0) }
        if let preview, closing.contains(preview) { self.preview = nil }
        if let selected, closing.contains(selected) { return id }
        return selected
    }

    /// Sürükle-bırak: sekmeyi hedefin konumuna taşır.
    public mutating func move(_ id: UUID, before target: UUID) {
        guard id != target,
              let from = tabs.firstIndex(of: id),
              let to = tabs.firstIndex(of: target) else { return }
        tabs.remove(at: from)
        tabs.insert(id, at: to)
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
