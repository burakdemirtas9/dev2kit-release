import SwiftUI

/// Tıklama hedefi ölçüleri.
///
/// SF Symbol'lerin kendi çerçevesi 12–14pt'de kalıyor ve `.buttonStyle(.plain)`
/// ile hit-test tam olarak o çerçeveye göre yapılıyor. macOS'ta rahat
/// tıklanabilir en küçük alan ~20pt; 13" ekranda aradaki fark "tıklayamıyorum,
/// nişan almam gerekiyor" olarak hissediliyor. Buradaki yardımcılar görünümü
/// değiştirmeden yalnızca hit-test alanını büyütür.
enum HitTarget {
    /// Simge düğmeleri için en küçük kare alan.
    static let icon: CGFloat = 22
    /// Liste satırları için en küçük yükseklik.
    static let row: CGFloat = 24
}

extension View {
    /// Simgenin görünümünü değiştirmeden tıklanabilir alanı büyütür.
    ///
    /// Button'ın *label*'ına uygulanmalı: `.plain` stilinde hit-test label
    /// çerçevesine göre yapılır, düğmenin dışına konan frame sayılmaz.
    func iconHitTarget(_ size: CGFloat = HitTarget.icon) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }

    /// Satırın tamamını (metnin bittiği yerden sonrası dahil) tıklanabilir yapar.
    func rowHitTarget(minHeight: CGFloat = HitTarget.row) -> some View {
        frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .contentShape(Rectangle())
    }
}
