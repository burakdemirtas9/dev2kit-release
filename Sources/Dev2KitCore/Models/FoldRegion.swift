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

    /// Katlı bölgenin özeti (açılışın arkasında gösterilir): nesnede anahtar,
    /// dizide eleman sayısı (doğrudan çocuklar, iç içe olanlar sayılmaz);
    /// XML/HTML'de gizli satır sayısı. Kullanıcı isteği (2026-10-19).
    public func summary(in characters: NSString) -> String {
        switch kind {
        case .object:
            let count = Self.directChildCount(in: characters, from: hiddenRange.location)
            return "… \(count) \(count == 1 ? "key" : "keys")"
        case .array:
            let count = Self.directChildCount(in: characters, from: hiddenRange.location)
            return "… \(count) \(count == 1 ? "item" : "items")"
        case .element:
            let lines = max(closeLine - openLine - 1, 0)
            return "… \(lines) \(lines == 1 ? "line" : "lines")"
        }
    }

    /// Açılış parantezinden sonraki ilk düzeydeki eleman sayısı: derinlik 0'da
    /// virgüller + 1 (içerik varsa). Dizgi içindeki ayraçlar sayılmaz.
    static func directChildCount(in text: NSString, from start: Int) -> Int {
        var depth = 0
        var commas = 0
        var hasContent = false
        var inString = false
        var escaped = false
        var index = start
        while index < text.length {
            let unit = text.character(at: index)
            index += 1
            if inString {
                if escaped { escaped = false } else if unit == 92 { escaped = true } else if unit == 34 { inString = false }
                continue
            }
            switch unit {
            case 34: inString = true; hasContent = true
            case 123, 91: depth += 1; hasContent = true      // { [
            case 125, 93:                                      // } ]
                if depth == 0 { return hasContent ? commas + 1 : 0 }
                depth -= 1
            case 44: if depth == 0 { commas += 1 }            // ,
            case 32, 9, 10, 13: break
            default: hasContent = true
            }
        }
        return hasContent ? commas + 1 : 0
    }
}
