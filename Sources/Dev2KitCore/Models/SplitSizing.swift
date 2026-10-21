import CoreGraphics

/// Bölünmüş görünümlerin boyut kuralları (kenar çubuğu, istek/yanıt,
/// Workbench girdi/çıktı, Geçmiş). Görünüm yalnızca çağırır.
public enum SplitSizing {
    /// Sürükleme: başlangıç boyutu + yer değişimi, sınırlar içinde.
    /// `upper < lower` ise (pencere çok dar) alt sınır kazanır: panel
    /// asgarisinin altına inmez.
    public static func resized(start: CGFloat, delta: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        clamp(start + delta, lower: lower, upper: upper)
    }

    public static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }

    /// İki panelli bölmede ilk panelin boyutu: `fraction` (0…1) toplamın
    /// payı; iki panelin asgarisi korunur. Pencere ikisine yetmiyorsa ilk
    /// panel asgarisinde kalır.
    public static func firstPane(fraction: CGFloat, available: CGFloat, minFirst: CGFloat, minSecond: CGFloat) -> CGFloat {
        let wanted = fraction.isFinite ? fraction * available : available / 2
        return clamp(wanted, lower: minFirst, upper: available - minSecond)
    }
}
