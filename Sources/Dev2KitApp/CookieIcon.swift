import SwiftUI

/// Kurabiye simgesi.
///
/// SF Symbols'de "cookie" yok; en yakın adaylar (`circle.grid.3x3.fill` gibi)
/// kurabiyeden çok düğmeye benziyor. Bu yüzden çizildi: dolu siluetten ısırık
/// ve damlalar oyulur. Isırık, kurabiyeyi başka yuvarlak simgelerden ayıran
/// asıl ipucu; damlalar 16pt'de kaybolmayacak kadar büyük, siluetin
/// yuvarlaklığını bozmayacak kadar küçük tutuldu.
///
/// Tek renk çizer ve `foregroundStyle`'ı izler, böylece toolbar'daki
/// SF Symbols'lerle aynı görünür.
struct CookieIcon: View {
    /// (merkeze göre x, y — yarıçap oranı), (boyut oranı)
    private static let chips: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = [
        (-0.40, -0.28, 0.075),
        (0.06, -0.34, 0.065),
        (-0.34, 0.34, 0.070),
        (0.26, 0.22, 0.075),
        (0.02, 0.62, 0.055),
    ]

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let radius = side / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            var path = Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: side, height: side
            ))

            // Sağ üstten ısırık.
            let biteRadius = side * 0.24
            let biteCenter = CGPoint(x: center.x + radius * 0.80, y: center.y - radius * 0.66)
            path = path.subtracting(Path(ellipseIn: CGRect(
                x: biteCenter.x - biteRadius, y: biteCenter.y - biteRadius,
                width: biteRadius * 2, height: biteRadius * 2
            )))

            // Damlalar negatif alan olarak oyulur; simetrik değiller ki
            // düğme izlenimi vermesin.
            for chip in Self.chips {
                let chipRadius = side * chip.radius
                let chipCenter = CGPoint(
                    x: center.x + chip.x * radius,
                    y: center.y + chip.y * radius
                )
                path = path.subtracting(Path(ellipseIn: CGRect(
                    x: chipCenter.x - chipRadius, y: chipCenter.y - chipRadius,
                    width: chipRadius * 2, height: chipRadius * 2
                )))
            }
            context.fill(path, with: .style(.foreground))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
