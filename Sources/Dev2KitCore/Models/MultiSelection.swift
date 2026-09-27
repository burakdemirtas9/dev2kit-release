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

    /// Bağlam menüsü hangi isteklere uygulanacak?
    ///
    /// macOS alışkanlığı: sağ tıklanan satır seçimin İÇİNDEYSE işlem tüm seçime,
    /// dışındaysa yalnızca o satıra uygulanır.
    public static func targets(forContextMenuOn id: UUID, selection: Set<UUID>) -> Set<UUID> {
        selection.contains(id) ? selection : [id]
    }
}
