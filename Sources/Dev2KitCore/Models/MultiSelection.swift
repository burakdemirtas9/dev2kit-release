import Foundation

/// Sidebar'da çoklu seçim kuralları.
///
/// Neden Core'da: "birden fazla istek seçiliyken detay panelinde hangisi
/// açık kalır" davranışsal bir karardır ve test edilmesi gerekir.
/// `List` çoklu seçimi (⇧ aralık, ⌘ tek tek) kendisi yapar; buradaki iş
/// yalnızca o kümeden AKTİF isteği türetmek.
public enum MultiSelection {
    /// Yeni seçim kümesine göre aktif (detayda açık) isteği belirler.
    ///
    /// - Aktif istek hâlâ kümedeyse korunur: kullanıcı ⇧ ile seçimi genişletirken
    ///   sağdaki panel yerinden oynamasın.
    /// - Kümede değilse sıralamadaki SON seçili istek aktif olur; kullanıcının
    ///   en son dokunduğu uç budur.
    /// - Küme boşsa aktif değişmez. Filtreleme açık isteği listeden düşürünce
    ///   AppKit seçimi boşaltıp geri yazıyor; o boşluk yok sayılmalı
    ///   (yoksa ⌘F ile arama yazmaya başlayınca açık istek kapanırdı).
    public static func active(current: UUID?, selection: Set<UUID>, order: [UUID]) -> UUID? {
        guard !selection.isEmpty else { return current }
        if let current, selection.contains(current) { return current }
        return order.last(where: selection.contains) ?? selection.first
    }

    /// Silinen/filtrelenen istekleri kümeden düşürür.
    public static func pruned(_ selection: Set<UUID>, live: Set<UUID>) -> Set<UUID> {
        selection.intersection(live)
    }

    /// Tıklamada basılı tuş: düz, ⌘ (tek tek ekle/çıkar), ⇧ (aralık).
    public enum Click: Sendable {
        case plain
        case toggle
        case range
    }

    /// `List` kullanmayan satırlar (Token Factory) için tıklama kuralı; Finder
    /// ile aynı. `anchor`: aralığın sabit ucu (son düz ya da ⌘ tıklanan).
    ///
    /// - Düz: yalnızca tıklanan; çapa o olur.
    /// - ⌘: tıklanan eklenir ya da çıkarılır; çapa o olur. Son öğe de
    ///   çıkarılabilir (küme boş kalır).
    /// - ⇧: çapadan tıklanana kadar olan aralık (sıra `order`'a göre) seçimin
    ///   yerine geçer; çapa değişmez. Çapa bu listede yoksa düz tıklama gibi.
    public static func click(
        _ id: UUID, _ click: Click, selection: Set<UUID>, anchor: UUID?, order: [UUID]
    ) -> (selection: Set<UUID>, anchor: UUID?) {
        switch click {
        case .plain:
            return ([id], id)
        case .toggle:
            var updated = selection
            if updated.contains(id) { updated.remove(id) } else { updated.insert(id) }
            return (updated, id)
        case .range:
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
                return ([id], id)
            }
            return (Set(order[min(from, to)...max(from, to)]), anchor)
        }
    }

    /// Bağlam menüsü hangi isteklere uygulanacak?
    ///
    /// macOS alışkanlığı: sağ tıklanan satır seçimin İÇİNDEYSE işlem tüm seçime,
    /// dışındaysa yalnızca o satıra uygulanır.
    public static func targets(forContextMenuOn id: UUID, selection: Set<UUID>) -> Set<UUID> {
        selection.contains(id) ? selection : [id]
    }
}
