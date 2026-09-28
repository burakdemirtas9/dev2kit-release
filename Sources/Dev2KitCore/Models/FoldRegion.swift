import Foundation

/// Editörde katlanabilir bir bölge.
///
/// Dilden bağımsız: JSON'da `{...}` / `[...]`, XML-HTML'de `<etiket>...</etiket>`
/// aynı şeye indirgenir — "şu satırda başlar, şu satırda biter, katlanınca şu
/// karakter aralığı gizlenir". Arayüz yalnızca çizer; hangi bölgelerin var
/// olduğunu dile özel tarayıcılar söyler (`JSONFolding`, `MarkupFolding`).
public struct FoldRegion: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case object
        case array
        /// XML / HTML etiketi.
        case element
    }

    /// Bölgeyi açan satır (0'dan başlar).
    public let openLine: Int
    /// Bölgeyi kapatan satır.
    public let closeLine: Int
    /// Katlanınca gizlenecek karakter aralığı: açılıştan SONRA başlar,
    /// kapanışın bulunduğu satırın BAŞINDAN önce biter.
    ///
    /// Kapanış satırı bilinçli olarak yerinde bırakılıyor: hem bloğun nerede
    /// bittiği görünür kalıyor, hem de son karakteri aynı satıra taşımanın
    /// TextKit tarafında çizim sorunu çıkardığı ölçüldü (yerleşim doğru
    /// oluyor ama son glyph ekrana gelmiyordu).
    public let hiddenRange: NSRange
    public let kind: Kind

    public var id: Int { hiddenRange.location }

    public init(openLine: Int, closeLine: Int, hiddenRange: NSRange, kind: Kind) {
        self.openLine = openLine
        self.closeLine = closeLine
        self.hiddenRange = hiddenRange
        self.kind = kind
    }

    /// Verilen satırda başlayan bölge (gutter'daki oka tıklanınca).
    public static func region(startingAt line: Int, in regions: [FoldRegion]) -> FoldRegion? {
        regions.first { $0.openLine == line }
    }

    /// İç içe bölgelerden yalnızca en dıştakiler — "tümünü kapat" bunları
    /// kapatır, içerdekileri kapatmanın görünür etkisi yok.
    public static func outermost(_ regions: [FoldRegion]) -> [FoldRegion] {
        var result: [FoldRegion] = []
        for region in regions {
            let isNested = result.contains { NSLocationInRange(region.hiddenRange.location, $0.hiddenRange) }
            if !isNested { result.append(region) }
        }
        return result
    }

    /// Açılışın bittiği yerden kapanış satırının başına kadar olan aralık.
    /// Tek satırlık bloklarda `nil` döner: katlamanın kazancı yok.
    ///
    /// `characters` metnin UTF-16 birimleri, `openEnd` gizlenecek ilk indeks,
    /// `closeStart` kapanış işaretinin başladığı indekstir.
    static func hiddenRange(
        from openEnd: Int,
        to closeStart: Int,
        in characters: [UInt16]
    ) -> NSRange? {
        var end = closeStart
        while end > openEnd, characters[end - 1] != 10 { end -= 1 }
        // Son satır sonu da görünür kalsın.
        let length = end - 1 - openEnd
        guard length > 0 else { return nil }
        return NSRange(location: openEnd, length: length)
    }
}
