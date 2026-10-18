import Foundation

/// Girdi/çıktı bölmesinin altındaki bilgi: boyut, satır, karakter.
public struct TextStats: Equatable, Sendable {
    public let bytes: Int
    public let lines: Int
    public let characters: Int

    public static let empty = TextStats(bytes: 0, lines: 0, characters: 0)

    public init(bytes: Int, lines: Int, characters: Int) {
        self.bytes = bytes
        self.lines = lines
        self.characters = characters
    }

    /// Tek geçişte sayar (UTF-8 bayt üzerinden; büyük metinde `Character`
    /// yürümek yavaş). Karakter sayısı Unicode skaler değil, kullanıcının
    /// gördüğü karakterdir; o yüzden yalnızca o kısım `count` ile.
    public init(_ text: String) {
        guard !text.isEmpty else { self = .empty; return }
        self.init(bytes: text.utf8.count, lines: Self.lineCount(text), characters: text.count)
    }

    /// Satır sayısı: `\n`, `\r\n` ve tek başına `\r` satır sonu (editör de
    /// öyle görüyor; yalnız `\n` saymak eski Mac biçimli metinde satır
    /// sınırını atlatıyordu). Boş metin 0 satır.
    public static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var lines = 1
        var previousWasCR = false
        for byte in text.utf8 {
            if byte == 0x0A {
                if !previousWasCR { lines += 1 }
                previousWasCR = false
            } else if byte == 0x0D {
                lines += 1
                previousWasCR = true
            } else {
                previousWasCR = false
            }
        }
        return lines
    }

    /// Aynı kural, editörün metni (`NSString`) üzerinde: köprülenmiş metnin
    /// UTF-8 görünümünü yürümek yavaş; UTF-16 birimleri parça parça okunur.
    /// Editör kapısı büyüyen her değişiklikte çağırıyor (4 MB'ta ölçüm testte).
    public static func lineCount(_ text: NSString) -> Int {
        let length = text.length
        guard length > 0 else { return 0 }
        var lines = 1
        var previousWasCR = false
        let chunk = 65_536
        var buffer = [unichar](repeating: 0, count: chunk)
        var location = 0
        while location < length {
            let count = min(chunk, length - location)
            text.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for index in 0..<count {
                let unit = buffer[index]
                if unit == 0x0A {
                    if !previousWasCR { lines += 1 }
                    previousWasCR = false
                } else if unit == 0x0D {
                    lines += 1
                    previousWasCR = true
                } else {
                    previousWasCR = false
                }
            }
            location += count
        }
        return lines
    }

    /// Boyut, Finder gibi 1000 tabanlı. `ByteCountFormatter` sistem diline
    /// göre yazıyordu ("bayt"); Workbench arayüzü İngilizce.
    public static func size(_ bytes: Int) -> String {
        if bytes < 1_000 { return "\(bytes) \(bytes == 1 ? "byte" : "bytes")" }
        let units = ["KB", "MB", "GB"]
        var value = Double(bytes) / 1_000
        var unit = 0
        while value >= 1_000, unit < units.count - 1 { value /= 1_000; unit += 1 }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", locale: Locale(identifier: "en_US"), value, units[unit])
    }

    /// "1.2 KB · 34 lines · 1,234 chars"
    public var summary: String {
        guard bytes > 0 else { return "" }
        let size = Self.size(bytes)
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.locale = Locale(identifier: "en_US")
        func format(_ value: Int) -> String { number.string(from: NSNumber(value: value)) ?? "\(value)" }
        return "\(size) · \(format(lines)) \(lines == 1 ? "line" : "lines") · \(format(characters)) chars"
    }
}
