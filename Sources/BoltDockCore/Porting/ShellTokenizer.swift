import Foundation

/// Shell komut satırını argümanlara böler.
///
/// cURL komutları panodan geldiği için tırnak ve kaçış kurallarının doğru
/// işlenmesi şart: yanlış bölünen bir komut sessizce yanlış isteğe dönüşür.
/// Desteklenenler: tek tırnak (ham), çift tırnak (kaçışlı), `$'...'`
/// (Chrome "Copy as cURL" bunu üretir), satır devamı `\`, yorum yok.
public enum ShellTokenizer {
    public struct TokenizeError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func tokenize(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        let chars = Array(input)
        var index = 0

        func flush() {
            if hasCurrent {
                tokens.append(current)
                current = ""
                hasCurrent = false
            }
        }

        while index < chars.count {
            let ch = chars[index]

            switch ch {
            case " ", "\t", "\n", "\r":
                flush()
                index += 1

            case "\\":
                // Satır devamı: ters bölü + yeni satır tamamen atlanır.
                if index + 1 < chars.count, chars[index + 1] == "\n" {
                    index += 2
                } else if index + 1 < chars.count, chars[index + 1] == "\r" {
                    index += (index + 2 < chars.count && chars[index + 2] == "\n") ? 3 : 2
                } else if index + 1 < chars.count {
                    current.append(chars[index + 1])
                    hasCurrent = true
                    index += 2
                } else {
                    throw TokenizeError(message: "Komut ters bölü ile bitiyor.")
                }

            case "'":
                hasCurrent = true
                index += 1
                var closed = false
                while index < chars.count {
                    if chars[index] == "'" { closed = true; index += 1; break }
                    current.append(chars[index])
                    index += 1
                }
                guard closed else { throw TokenizeError(message: "Kapatılmamış tek tırnak (').") }

            case "\"":
                hasCurrent = true
                index += 1
                var closed = false
                while index < chars.count {
                    if chars[index] == "\\", index + 1 < chars.count {
                        let next = chars[index + 1]
                        // Çift tırnak içinde yalnızca bu karakterler kaçışlıdır.
                        if next == "\"" || next == "\\" || next == "$" || next == "`" {
                            current.append(next)
                            index += 2
                            continue
                        }
                        if next == "\n" { index += 2; continue }
                        current.append("\\")
                        index += 1
                        continue
                    }
                    if chars[index] == "\"" { closed = true; index += 1; break }
                    current.append(chars[index])
                    index += 1
                }
                guard closed else { throw TokenizeError(message: "Kapatılmamış çift tırnak (\").") }

            case "$" where index + 1 < chars.count && chars[index + 1] == "'":
                hasCurrent = true
                index += 2
                var closed = false
                while index < chars.count {
                    if chars[index] == "\\", index + 1 < chars.count {
                        let (text, consumed) = decodeANSIEscape(chars, at: index + 1)
                        current += text
                        index += 1 + consumed
                        continue
                    }
                    if chars[index] == "'" { closed = true; index += 1; break }
                    current.append(chars[index])
                    index += 1
                }
                guard closed else { throw TokenizeError(message: "Kapatılmamış $'...' bloğu.") }

            default:
                current.append(ch)
                hasCurrent = true
                index += 1
            }
        }
        flush()
        return tokens
    }

    /// `$'...'` içindeki kaçış dizisini çözer; (metin, tüketilen karakter) döner.
    private static func decodeANSIEscape(_ chars: [Character], at index: Int) -> (String, Int) {
        guard index < chars.count else { return ("\\", 0) }
        switch chars[index] {
        case "n": return ("\n", 1)
        case "t": return ("\t", 1)
        case "r": return ("\r", 1)
        case "\\": return ("\\", 1)
        case "'": return ("'", 1)
        case "\"": return ("\"", 1)
        case "0": return ("\0", 1)
        case "x":
            var hex = ""
            var offset = index + 1
            while offset < chars.count, hex.count < 2, chars[offset].isHexDigit {
                hex.append(chars[offset])
                offset += 1
            }
            if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                return (String(Character(scalar)), 1 + hex.count)
            }
            return ("x", 1)
        case "u":
            var hex = ""
            var offset = index + 1
            while offset < chars.count, hex.count < 4, chars[offset].isHexDigit {
                hex.append(chars[offset])
                offset += 1
            }
            if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                return (String(Character(scalar)), 1 + hex.count)
            }
            return ("u", 1)
        default:
            return (String(chars[index]), 1)
        }
    }
}
