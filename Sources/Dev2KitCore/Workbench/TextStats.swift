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
        var lines = 1
        for byte in text.utf8 where byte == 0x0A { lines += 1 }
        self.init(bytes: text.utf8.count, lines: lines, characters: text.count)
    }

    /// Boyut, Finder gibi 1000 tabanlı. `ByteCountFormatter` sistem diline
    /// göre yazıyordu ("bayt"); Workbench arayüzü İngilizce.
    static func size(_ bytes: Int) -> String {
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
