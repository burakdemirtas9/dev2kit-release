import Foundation

/// JavaScript gövdelerini süslü parantez yapısına göre girintiler.
///
/// Tam bir JS parser değildir (Prettier gibi satır genişliğine göre sarma,
/// operatör hizalama yapmaz). String, template literal, yorum ve regex
/// literalleri atomik olarak korunur; girinti `{}` `[]` `()` dengesine göre
/// kurulur. Boş satırlar normalize edilir.
public enum ScriptFormatter {
    public struct FormatError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func beautify(_ text: String, indent: String = "  ") throws -> String {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !chars.isEmpty else {
            throw FormatError(message: "Geçersiz JavaScript: içerik boş")
        }

        var out = ""
        var level = 0
        var stack: [Character] = []
        var index = 0
        /// Regex literal mi bölme operatörü mü ayırmak için son anlamlı karakter.
        var lastMeaningful: Character?

        func trimTrailing() {
            while let last = out.last, last == " " || last == "\n" { out.removeLast() }
        }
        func newline() {
            trimTrailing()
            guard !out.isEmpty else { return }
            out += "\n" + String(repeating: indent, count: level)
        }
        func append(_ piece: String) {
            out += piece
            if let last = piece.last, !last.isWhitespace { lastMeaningful = last }
        }
        func nextNonSpace(after position: Int) -> Character? {
            var i = position
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            return i < chars.count ? chars[i] : nil
        }
        /// `/` bu konumda regex başlatıyor mu? Önceki anlamlı karakter bir
        /// değer sonuysa (identifier, sayı, `)`, `]`) bölme operatörüdür.
        var regexAllowed: Bool {
            guard let last = lastMeaningful else { return true }
            return !(last.isLetter || last.isNumber || last == ")" || last == "]" || last == "_" || last == "$")
        }
        func readUntil(_ terminator: String, from: Int) -> Int? {
            let needle = Array(terminator)
            var i = from
            while i + needle.count <= chars.count {
                if Array(chars[i..<(i + needle.count)]) == needle { return i + needle.count - 1 }
                i += 1
            }
            return nil
        }
        /// Kaçış karakterlerine saygı duyarak kapanış sınırlayıcısını bulur.
        func readDelimited(open: Character, from: Int) -> Int? {
            var i = from + 1
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == open { return i }
                if open != "`", chars[i] == "\n" { return nil }
                i += 1
            }
            return nil
        }

        while index < chars.count {
            let ch = chars[index]

            if ch.isWhitespace {
                if let last = out.last, last != " ", last != "\n" { out += " " }
                index += 1
                continue
            }

            // Yorumlar
            if ch == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                var end = index
                while end < chars.count, chars[end] != "\n" { end += 1 }
                newline()
                append(String(chars[index..<end]))
                newline()
                index = end
                continue
            }
            if ch == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                guard let end = readUntil("*/", from: index + 2) else {
                    throw FormatError(message: "Geçersiz JavaScript: /* yorumu */ ile kapatılmamış.")
                }
                newline()
                append(String(chars[index...end]))
                newline()
                index = end + 1
                continue
            }

            // String ve template literal
            if ch == "\"" || ch == "'" || ch == "`" {
                guard let end = readDelimited(open: ch, from: index) else {
                    throw FormatError(message: "Geçersiz JavaScript: \(ch) ile açılan metin kapatılmamış.")
                }
                append(String(chars[index...end]))
                index = end + 1
                continue
            }

            // Regex literal
            if ch == "/", regexAllowed, let end = readDelimited(open: "/", from: index) {
                var last = end
                while last + 1 < chars.count, chars[last + 1].isLetter { last += 1 }
                append(String(chars[index...last]))
                index = last + 1
                continue
            }

            switch ch {
            case "{":
                // Boş gövde tek satırda kalsın: {}
                if nextNonSpace(after: index + 1) == "}" {
                    trimTrailing()
                    append(out.isEmpty ? "{}" : " {}")
                    var skip = index + 1
                    while chars[skip] != "}" { skip += 1 }
                    index = skip + 1
                    continue
                }
                trimTrailing()
                append(out.isEmpty ? "{" : " {")
                stack.append("{")
                level += 1
                newline()
                index += 1

            case "}":
                guard stack.last == "{" else {
                    throw FormatError(message: "Geçersiz JavaScript: eşleşmeyen } karakteri.")
                }
                stack.removeLast()
                level = max(0, level - 1)
                newline()
                append("}")
                index += 1

            case "(", "[":
                append(String(ch))
                stack.append(ch)
                index += 1

            case ")", "]":
                let expected: Character = ch == ")" ? "(" : "["
                guard stack.last == expected else {
                    throw FormatError(message: "Geçersiz JavaScript: eşleşmeyen \(ch) karakteri.")
                }
                stack.removeLast()
                trimTrailing()
                append(String(ch))
                index += 1

            case ";":
                trimTrailing()
                append(";")
                // for(;;) içindeki ; satır sonu yapmamalı.
                if !stack.contains("(") { newline() }
                index += 1

            case ",":
                trimTrailing()
                append(",")
                // Nesne literalinde her alan kendi satırında; dizi ve
                // argüman listeleri satır içinde kalır.
                if stack.last == "{" { newline() } else { append(" ") }
                index += 1

            case ":":
                trimTrailing()
                append(": ")
                index += 1

            default:
                append(String(ch))
                index += 1
            }
        }

        if let unclosed = stack.last {
            throw FormatError(message: "Geçersiz JavaScript: \(unclosed) kapatılmamış.")
        }
        trimTrailing()
        return out
    }
}
