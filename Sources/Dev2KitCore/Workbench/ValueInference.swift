import Foundation

/// Düz sayı kuralı: Properties → YAML'da hangi değerin tırnaksız sayı
/// yazılacağı (önceden CSV/XML → JSON'un "Detect types"ı; o araçlar
/// 2026-10-20'de kaldırıldı).
///
/// Tutucu: yanlış tahmin veriyi bozar, kaçırılan tahmin yalnızca tırnak bırakır.
/// - `012`, `+1`, `.5`, `1,5` metin kalır (posta kodu, telefon, yerel ondalık).
/// - 15'ten fazla basamaklı sayı metin kalır: kart, IBAN parçası, TCKN gibi
///   kimlikler JavaScript'te (double) hassasiyet kaybeder.
enum ValueInference {
    static let maxNumberDigits = 15

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
