import Foundation

/// Metin hücresinden JSON değeri tahmini ("Detect types"): CSV → JSON ve
/// XML → JSON ortak kuralı.
///
/// Tutucu: yanlış tahmin veriyi bozar, kaçırılan tahmin yalnızca tırnak bırakır.
/// - `012`, `+1`, `.5`, `1,5` metin kalır (posta kodu, telefon, yerel ondalık).
/// - 15'ten fazla basamaklı sayı metin kalır: kart, IBAN parçası, TCKN gibi
///   kimlikler JavaScript'te (double) hassasiyet kaybeder.
/// - `[`/`{` ile başlayıp geçerli JSON olan hücre değer olur: JSON → CSV
///   dizileri hücreye JSON metni olarak yazar, gidiş-dönüş tutarlı kalsın.
enum ValueInference {
    static let maxNumberDigits = 15

    static func value(of text: String, emptyIsNull: Bool) -> JSONValue {
        switch text {
        case "": return emptyIsNull ? .null : .string("")
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: break
        }
        if isPlainNumber(text) { return .number(text) }
        if let first = text.first, first == "[" || first == "{",
           let value = try? JSONDocument.parse(text), value.isContainer {
            return value
        }
        return .string(text)
    }

    /// JSON sayı dilbilgisi (`-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?`) ve
    /// basamak sınırı.
    static func isPlainNumber(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        var digits = 0
        func isDigit(_ i: Int) -> Bool { i < bytes.count && (0x30...0x39).contains(bytes[i]) }
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard isDigit(index) else { return false }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
            digits += 1
            if isDigit(index) { return false }
        } else {
            while isDigit(index) { index += 1; digits += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard isDigit(index) else { return false }
            while isDigit(index) { index += 1; digits += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard isDigit(index) else { return false }
            while isDigit(index) { index += 1 }
        }
        return index == bytes.count && digits <= maxNumberDigits
    }
}
