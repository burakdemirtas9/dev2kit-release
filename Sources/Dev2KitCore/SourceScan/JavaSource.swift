import Foundation

/// Tek bir Java kaynak dosyasının hafif çözümlemesi.
///
/// Tam bir derleyici değildir; Spring/Feign kalıplarını bulmaya yetecek kadar
/// yapı çıkarır: yorumlar atılır (metin sabitlerine dokunmadan), parantez ve
/// süslü parantez eşleştirilir, annotation argümanları ayrıştırılır.
/// Kod hiçbir zaman derlenmez ya da çalıştırılmaz.
public struct JavaSource: Sendable {
    public let path: String
    /// Yorumları boşlukla değiştirilmiş metin; konumlar ve satırlar korunur.
    let code: [Character]
    let text: String
    private let lineStarts: [Int]

    public init(path: String, text: String) {
        self.path = path
        let stripped = Self.stripComments(Array(text))
        self.code = stripped
        self.text = String(stripped)
        var starts = [0]
        for (index, character) in stripped.enumerated() where character == "\n" { starts.append(index + 1) }
        self.lineStarts = starts
    }

    func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    func location(_ offset: Int) -> String { "\(path):\(line(at: offset))" }

    /// Dosyadaki ilk tür adı (class/interface/enum/record).
    var primaryTypeName: String? {
        firstMatch(#"\b(?:class|interface|enum|record)\s+([A-Za-z_]\w*)"#)?.first
    }

    // MARK: - Yorum temizleme

    /// `//`, `/* */` yorumlarını boşlukla değiştirir; metin sabitleri
    /// (text block dahil) ve karakter sabitleri korunur.
    static func stripComments(_ input: [Character]) -> [Character] {
        var output = input
        var index = 0
        let count = input.count
        func blank(_ range: Range<Int>) {
            for i in range where output[i] != "\n" { output[i] = " " }
        }
        while index < count {
            let character = input[index]
            let next: Character? = index + 1 < count ? input[index + 1] : nil
            if character == "/", next == "/" {
                let start = index
                while index < count, input[index] != "\n" { index += 1 }
                blank(start..<index)
            } else if character == "/", next == "*" {
                let start = index
                index += 2
                while index + 1 < count, !(input[index] == "*" && input[index + 1] == "/") { index += 1 }
                index = min(index + 2, count)
                blank(start..<index)
            } else if character == "\"" {
                if index + 2 < count, input[index + 1] == "\"", input[index + 2] == "\"" {
                    index += 3
                    while index + 2 < count, !(input[index] == "\"" && input[index + 1] == "\"" && input[index + 2] == "\"") { index += 1 }
                    index = min(index + 3, count)
                } else {
                    index = skipQuoted(input, from: index, quote: "\"")
                }
            } else if character == "'" {
                index = skipQuoted(input, from: index, quote: "'")
            } else {
                index += 1
            }
        }
        return output
    }

    /// Tırnaklı metnin (kaçışlara saygıyla) sonrasındaki konum. Modül içi:
    /// `DeclarativeClients` de kullanıyor (önceden birebir kopyası vardı).
    static func skipQuoted(_ input: [Character], from start: Int, quote: Character) -> Int {
        var index = start + 1
        while index < input.count {
            if input[index] == "\\" { index += 2; continue }
            if input[index] == quote || input[index] == "\n" { return index + 1 }
            index += 1
        }
        return input.count
    }

    // MARK: - Yapı

    /// `open` konumundaki açılış karakterinin eşinin konumu; metin sabitleri atlanır.
    func matching(from open: Int) -> Int? {
        guard open < code.count else { return nil }
        let opener = code[open]
        let closer: Character
        switch opener {
        case "(": closer = ")"
        case "{": closer = "}"
        case "[": closer = "]"
        case "<": closer = ">"
        default: return nil
        }
        var depth = 0
        var index = open
        while index < code.count {
            let character = code[index]
            if character == "\"" || character == "'" {
                index = Self.skipQuoted(code, from: index, quote: character)
                continue
            }
            if character == opener { depth += 1 }
            if character == closer {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    func slice(_ range: Range<Int>) -> String {
        String(code[max(0, range.lowerBound)..<min(code.count, range.upperBound)])
    }

    func firstMatch(_ pattern: String) -> [String]? {
        matches(pattern).first?.groups
    }

    /// Düzenli ifade eşleşmeleri (yakalama grupları ve başlangıç konumu).
    func matches(_ pattern: String) -> [(offset: Int, groups: [String])] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        // NSString UTF-16 ofsetleri Character ofsetiyle aynı değildir (emoji,
        // birleşik karakter). Eşleşmeler sıralı geldiği için artımlı çevrilir.
        var utf16Cursor = 0
        var characterCursor = 0
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            characterCursor += ns.substring(with: NSRange(location: utf16Cursor, length: match.range.location - utf16Cursor)).count
            utf16Cursor = match.range.location
            let offset = characterCursor
            let groups = (1..<match.numberOfRanges).map { i -> String in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            return (offset, groups)
        }
    }
}

/// Java ifadelerinin küçük yardımcıları.
enum JavaSyntax {
    /// En üst düzeydeki virgüllere göre böler (parantez, köşeli, süslü ve
    /// açılı parantezlerin ve metin sabitlerinin içi bölünmez).
    static func splitTopLevel(_ text: String, separator: Character = ",") -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escape = false
        for character in text {
            if let active = quote {
                current.append(character)
                if escape { escape = false } else if character == "\\" { escape = true } else if character == active { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "(", "[", "{", "<":
                depth += 1
                current.append(character)
            case ")", "]", "}", ">":
                depth -= 1
                current.append(character)
            case separator where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            default:
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty || !parts.isEmpty { parts.append(last) }
        return parts
    }

    /// Annotation argümanları: `("x")` → value, `(name = "x", url = "${y}")`.
    static func annotationArguments(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in splitTopLevel(raw) where !part.isEmpty {
            if let equals = topLevelEquals(part) {
                let key = String(part[..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(part[part.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                result[key] = value
            } else {
                result["value"] = part
            }
        }
        return result
    }

    /// `==` ya da metin içindeki `=` değil, atama işareti.
    private static func topLevelEquals(_ text: String) -> String.Index? {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" || character == "{" {
                return nil
            } else if character == "=" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "=" { return nil }
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Tek bir Java metin sabitinin değeri (`"a\"b"` → `a"b`); sabit değilse nil.
    static func stringLiteral(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else { return nil }
        var result = ""
        var escape = false
        for character in trimmed.dropFirst().dropLast() {
            if escape {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escape = false
            } else if character == "\\" {
                escape = true
            } else if character == "\"" {
                return nil  // "a" + "b" gibi birden çok sabit: tek sabit değil
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// `{"a", "b"}` dizisinin ilk elemanı; dizi değilse kendisi.
    static func firstArrayElement(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return trimmed }
        return splitTopLevel(String(trimmed.dropFirst().dropLast())).first ?? ""
    }
}
