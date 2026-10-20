import Foundation

/// Dairesel menünün geometrisi ve sırası (araç çubuğundaki Ayarlar menüsü).
///
/// Neden Core'da: "öğe nerede durur, oraya hangi yoldan gider, hangi sırayla
/// açılır/kapanır" davranışsal kurallar; görünüm yalnızca bu değerleri çizer.
///
/// Koordinatlar ekran yönünde (y aşağı), başlangıç noktası tetikleyici
/// düğmenin (Ayarlar) merkezi. Düğme son durumda çemberin TEPESİNDE durur;
/// çemberin merkezi onun `radius` kadar altında. Öğe 0 düğmenin kendisidir,
/// diğerleri saat yönünde eşit açıyla dizilir (6 öğede: üst, sağ üst, sağ
/// alt, alt, sol alt, sol üst).
public struct RadialMenuLayout: Equatable, Sendable {
    /// Öğe sayısı (tetikleyici dahil). En az 2.
    public var count: Int
    /// Görünmeyen çemberin yarıçapı (pt).
    public var radius: Double
    /// Hareketin kavisi: 0 düz çizgi (kiriş), 1 çemberin kendisi. Ara
    /// değerler "hafif kavis": yol saat yönüne doğru dışa bükülür.
    public var curvature: Double
    /// Doğarken ölçek (küçük bir nokta).
    public var minimumScale: Double

    public init(count: Int, radius: Double, curvature: Double = 0.35, minimumScale: Double = 0.12) {
        self.count = max(2, count)
        self.radius = radius
        self.curvature = min(max(curvature, 0), 1)
        self.minimumScale = min(max(minimumScale, 0), 1)
    }

    /// Çemberin merkezi (tetikleyiciye göre).
    public var center: CGPoint { CGPoint(x: 0, y: radius) }

    /// Öğenin son açısı (radyan; 0 = sağ, saat yönü artar, tepe −π/2).
    public func angle(of index: Int) -> Double {
        -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(count)
    }

    /// Öğenin son konumu.
    public func finalPosition(of index: Int) -> CGPoint {
        point(onCircleAt: angle(of: index))
    }

    /// `progress` (0 doğuş, 1 yerleşmiş) anındaki konum. Yol, tetikleyiciden
    /// kiriş ile çember yayının karışımı: 0'da ve 1'de ikisi de aynı uçlarda,
    /// arada yay saat yönüne doğru dışa taşır. Yaylanma 1'i biraz aşabilir;
    /// formül aşan değerde de sürekli.
    public func position(of index: Int, progress: Double) -> CGPoint {
        let target = finalPosition(of: index)
        let chord = CGPoint(x: target.x * progress, y: target.y * progress)
        guard curvature > 0, index > 0 else { return chord }
        let start = -Double.pi / 2
        let arc = point(onCircleAt: start + (angle(of: index) - start) * progress)
        return CGPoint(
            x: chord.x + (arc.x - chord.x) * curvature,
            y: chord.y + (arc.y - chord.y) * curvature
        )
    }

    /// Ölçek: nokta boyutundan tam boyuta. Önce açılan öğe (ilerlemesi
    /// büyük) sonrakinden büyük görünür; sonunda hepsi 1.
    public func scale(progress: Double) -> Double {
        minimumScale + (1 - minimumScale) * max(progress, 0)
    }

    /// Görünürlük: yolun ilk üçte birinde dolar (yalnızca fade-in değil;
    /// konum ve ölçekle birlikte ilerler).
    public func opacity(progress: Double) -> Double {
        min(max(progress * 3, 0), 1)
    }

    /// Açılma sırası: tetikleyiciden sonra saat yönünde (1, 2, …).
    public var openingOrder: [Int] { Array(1..<count) }

    /// Kapanma sırası: tersi, son açılan ilk kapanır.
    public var closingOrder: [Int] { openingOrder.reversed() }

    /// Tüm öğeleri (ve çevredeki boşluğu) içeren dikdörtgen; tetikleyiciye
    /// göre. `itemDiameter` öğenin çapı, `margin` gölge/ışıma payı.
    public func bounds(itemDiameter: Double, margin: Double = 0) -> CGRect {
        let half = itemDiameter / 2 + margin
        let points = (0..<count).map(finalPosition(of:))
        let xs = points.map { Double($0.x) }, ys = points.map { Double($0.y) }
        let minX = (xs.min() ?? 0) - half, maxX = (xs.max() ?? 0) + half
        let minY = (ys.min() ?? 0) - half, maxY = (ys.max() ?? 0) + half
        return CGRect(origin: CGPoint(x: minX, y: minY), size: CGSize(width: maxX - minX, height: maxY - minY))
    }

    /// İki komşu öğe arasındaki boşluk (çaplar çıktıktan sonra). Negatifse
    /// öğeler çakışır; yarıçap büyütülmeli.
    public func gap(itemDiameter: Double) -> Double {
        2 * radius * sin(Double.pi / Double(count)) - itemDiameter
    }

    /// Öğelerin çakışmayacağı en küçük yarıçap.
    public static func minimumRadius(count: Int, itemDiameter: Double, gap: Double) -> Double {
        (itemDiameter + gap) / (2 * sin(Double.pi / Double(max(2, count))))
    }

    private func point(onCircleAt angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
}
