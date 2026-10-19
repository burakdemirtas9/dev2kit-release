import Foundation

/// JSON → YAML (docs/V2.md "1e") ve Properties → YAML; okuma `YAMLReader`.
///
/// - Blok stil, 2 boşluk girinti. YAML girintide sekmeye izin vermiyor;
///   girinti seçeneği bu yüzden yok.
/// - Boş nesne/dizi `{}` / `[]`.
/// - Tutucu tırnaklama: YAML'ın başka tip okuyabileceği her metin çift
///   tırnaklanır (JSON string yazımı geçerli bir YAML çift tırnaklı
///   değeridir). Ünlü "Norway problemi": YAML 1.1 okuyucuları (PyYAML,
///   SnakeYAML) `no`, `on`, `yes`'i boolean, `012`'yi sekizli, `2024-01-01`'i
///   tarih okur. Rakam, `+`, `-`, `.` ile başlayan her metin tırnaklanır.
/// - JSONC yorumları düşer.
public enum YAMLWriter {
    static let indent = "  "
    private static let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "y", "n", "null", "~", "<<", "="]
    private static let indicators = Set("-?:,[]{}#&*!|>'\"%@`+.0123456789 ")

    public static func fromJSON(_ input: String) throws -> String {
        write(try JSONDocument.parse(input))
    }

    public static func write(_ value: JSONValue) -> String {
        block(value).joined(separator: "\n")
    }

    private static func block(_ value: JSONValue) -> [String] {
        if let text = inline(value) { return [text] }
        var lines: [String] = []
        switch value {
        case .object(let members):
            for member in members {
                let key = scalar(member.key)
                if let text = inline(member.value) {
                    lines.append("\(key): \(text)")
                } else {
                    lines.append("\(key):")
                    lines += block(member.value).map { indent + $0 }
                }
            }
        case .array(let items):
            for item in items {
                let sub = block(item)
                lines.append("- " + sub[0])
                lines += sub.dropFirst().map { indent + $0 }
            }
        default:
            break
        }
        return lines
    }

    /// Tek satırda yazılabilen değer; dolu kapsayıcı için `nil`.
    private static func inline(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return scalar(text)
        case .number(let raw): return raw
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .object(let members): return members.isEmpty ? "{}" : nil
        case .array(let items): return items.isEmpty ? "[]" : nil
        }
    }

    static func scalar(_ text: String) -> String {
        needsQuotes(text) ? JSONValue.quoted(text) : text
    }

    static func needsQuotes(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        if indicators.contains(first) || last == " " || last == ":" { return true }
        if reserved.contains(text.lowercased()) { return true }
        if text.contains(": ") || text.contains(" #") { return true }
        return text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x85
                || scalar.value == 0x2028 || scalar.value == 0x2029 || scalar.value == 0xFEFF
        }
    }
}
