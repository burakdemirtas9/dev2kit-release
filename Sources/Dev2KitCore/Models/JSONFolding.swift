import Foundation

/// Metinde katlanabilir `{...}` / `[...]` bölgeleri.
///
/// Neden Core'da: "hangi parantez hangisiyle eşleşir, dizgi içindeki parantez
/// sayılmaz" kuralı davranıştır ve test edilmesi gerekir. Arayüz yalnızca
/// çizer.
///
/// Ayrıştırıcı bilinçli olarak gevşek: geçersiz JSON'da da çalışır. Kullanıcı
/// yazarken metin çoğu zaman yarımdır; katlama o sırada da bozulmamalı.
public enum JSONFolding {
    public struct Region: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case object
            case array
        }

        /// Açılış parantezinin bulunduğu satır (0'dan başlar).
        public let openLine: Int
        /// Kapanış parantezinin bulunduğu satır.
        public let closeLine: Int
        /// Katlanınca gizlenecek karakter aralığı: açılış parantezinden SONRA
        /// başlar, kapanış parantezinin bulunduğu satırın BAŞINDAN önce biter.
        ///
        /// Kapanış satırı bilinçli olarak yerinde bırakılıyor: hem bloğun
        /// nerede bittiği görünür kalıyor, hem de son karakteri aynı satıra
        /// taşımanın TextKit tarafında çizim sorunu çıkardığı ölçüldü
        /// (yerleşim doğru oluyor ama son glyph ekrana gelmiyordu).
        public let hiddenRange: NSRange
        public let kind: Kind

        public var id: Int { hiddenRange.location }

        public init(openLine: Int, closeLine: Int, hiddenRange: NSRange, kind: Kind) {
            self.openLine = openLine
            self.closeLine = closeLine
            self.hiddenRange = hiddenRange
            self.kind = kind
        }
    }

    /// Tek satırda başlayıp biten bloklar katlanmaz: katlamanın kazancı yok.
    public static func regions(in text: String) -> [Region] {
        let characters = Array(text.utf16)
        var stack: [(index: Int, line: Int, kind: Region.Kind)] = []
        var regions: [Region] = []
        var line = 0
        var inString = false
        var escaped = false

        for (index, unit) in characters.enumerated() {
            let character = Character(UnicodeScalar(unit) ?? " ")

            if escaped {
                escaped = false
                continue
            }
            if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                else if character == "\n" { line += 1 }   // bozuk JSON'da satır kaçmasın
                continue
            }

            switch character {
            case "\"": inString = true
            case "\n": line += 1
            case "{": stack.append((index, line, .object))
            case "[": stack.append((index, line, .array))
            case "}", "]":
                guard let open = stack.popLast() else { continue }
                guard line > open.line else { continue }   // tek satırlık blok
                let start = open.index + 1
                // Kapanış satırının başındaki satır sonuna kadar gizlenir;
                // böylece kapanış parantezi kendi satırında kalır.
                var end = index
                while end > start, characters[end - 1] != 10 { end -= 1 }
                let length = max(0, end - 1 - start)      // son satır sonu da kalsın
                guard length > 0 else { continue }
                regions.append(
                    Region(
                        openLine: open.line,
                        closeLine: line,
                        hiddenRange: NSRange(location: start, length: length),
                        kind: open.kind
                    )
                )
            default:
                break
            }
        }

        // Dıştan içe sıra: arayüz "tümünü kapat"ta önce dış bloğu işler.
        return regions.sorted { $0.hiddenRange.location < $1.hiddenRange.location }
    }

    /// Verilen satırda başlayan bölge (gutter'daki oka tıklanınca).
    public static func region(startingAt line: Int, in regions: [Region]) -> Region? {
        regions.first { $0.openLine == line }
    }

    /// İç içe bölgelerden yalnızca en dıştakiler — "tümünü kapat" bunları kapatır,
    /// içerdekileri kapatmanın görünür etkisi yok.
    public static func outermost(_ regions: [Region]) -> [Region] {
        var result: [Region] = []
        for region in regions {
            let isNested = result.contains { NSLocationInRange(region.hiddenRange.location, $0.hiddenRange) }
            if !isNested { result.append(region) }
        }
        return result
    }
}
