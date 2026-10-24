import CoreGraphics

/// Sol panelin (istek listesi / Workbench araç listesi) genişlik kuralları.
///
/// Asgari genişlik, araç çubuğunun solundaki logonun panelin üstünde
/// sığmasından gelir: logonun penceredeki sağ kenarı + pay. Ölçü pencere
/// koordinatında, macOS point'iyle (ekran çözünürlüğü / Retina ölçeği
/// değil); pencere başka monitöre taşınınca değişmez. Logo konumu macOS
/// sürümüne göre değişebildiği için (pencere düğmelerinin aralığı) sabit
/// değil, çalışırken ölçülür; ölçülene kadar tahmin kullanılır.
public enum SidebarSizing {
    /// Logo olmasa da geçerli taban (önceki sabit asgari).
    public static let baseMinimum: CGFloat = 220
    /// Sağdaki istek/yanıt alanına bırakılacak en az genişlik.
    public static let detailMinimum: CGFloat = 480
    /// Logonun sağı ile panel kenarı arası.
    public static let logoTrailingPadding: CGFloat = 16
    /// Logonun ölçülmeden önceki sol kenarı (pencere düğmeleri + boşluk;
    /// macOS 27, ekran dışı pencerede ölçüldü: 96,5). İlk karede sıçrama olmasın.
    public static let estimatedLogoLeading: CGFloat = 96

    /// Asgari genişlik: logonun penceredeki sağ kenarı + pay, tabandan az değil.
    /// - Parameter logoTrailingEdge: ölçülen sağ kenar (pencere koordinatı);
    ///   `nil` ise tahmin.
    public static func minimumWidth(logoTrailingEdge: CGFloat?, logoWidth: CGFloat) -> CGFloat {
        let edge = logoTrailingEdge.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? estimatedLogoLeading + logoWidth
        return max(baseMinimum, (edge + logoTrailingPadding).rounded(.up))
    }

    /// Üst sınır: içerik ölçüsü (en uzun ad) ve pencerede detay alanına
    /// kalan yer. Dar pencerede bu asgarinin altına düşebilir; o durumda
    /// asgari kazanır (`width`), logo sıkışmaz.
    public static func upperBound(contentMaximum: CGFloat, totalWidth: CGFloat, divider: CGFloat) -> CGFloat {
        min(contentMaximum, totalWidth - detailMinimum - divider)
    }

    /// Gösterilecek genişlik: tercih sınırlar içine alınır (tercih değişmez).
    public static func width(preferred: CGFloat, minimum: CGFloat, upper: CGFloat) -> CGFloat {
        SplitSizing.clamp(preferred, lower: minimum, upper: upper)
    }

    /// Kayıtlı tercih: yoksa, bozuksa ya da asgarinin altındaysa asgari;
    /// geçerliyse olduğu gibi.
    public static func restoredPreference(_ stored: Double, minimum: CGFloat) -> CGFloat {
        guard stored.isFinite, CGFloat(stored) >= minimum else { return minimum }
        return CGFloat(stored)
    }
}
