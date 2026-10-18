import Foundation

/// Tam sözdizimi okuyucusu olmayan dillerde (CSS, SQL) yapısal kontrol:
/// parantez dengesi, kapanmamış string/yorum. Hata
/// konumuyla döner. Sonuç `.structurallyValid`: arayüz "geçerli" DEMEZ.
///
/// Tarama `CodeScanner` ile (biçimlendiricilerle aynı string/yorum kuralları).
public enum StructureCheck {
    public struct Rules: Sendable {
        let language: String
        let quotes: Set<Character>
        /// SQL: `--` satır yorumu, tırnak tekrarıyla kaçış (`'it''s'`), ters
        /// bölü kaçış değil (`'C:\'`), metin satır atlayabilir.
        var sqlQuoting = false

        public static let css = Rules(language: "CSS", quotes: ["\"", "'"])
        public static let sql = Rules(language: "SQL", quotes: ["\"", "'", "`"], sqlQuoting: true)
    }

    public static func validate(_ text: String, rules: Rules) -> WorkbenchValidation {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        var scanner = CodeScanner(text)
        var stack: [(char: Character, offset: Int)] = []
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]

        func issue(_ message: String, at offset: Int) -> WorkbenchValidation {
            .invalid(.at(characterOffset: offset, in: scanner.chars, message: "Geçersiz \(rules.language): \(message)"))
        }

        while !scanner.isAtEnd {
            let ch = scanner.current
            let start = scanner.index
            if ch.isWhitespace { scanner.index += 1; continue }
            if rules.sqlQuoting, ch == "-", scanner.peek() == "-" {
                while !scanner.isAtEnd, !scanner.current.isNewline { scanner.index += 1 }
                continue
            }
            // `/* */` yorumu; `//` yorum değil (CSS'te `url(http://…)`).
            if ch == "/", scanner.peek() == "*" {
                guard (try? scanner.readComment(language: rules.language)) != nil else {
                    return issue("/* yorumu */ ile kapatılmamış", at: start)
                }
                continue
            }
            if rules.quotes.contains(ch) {
                guard scanner.readQuoted(
                    multiline: rules.sqlQuoting,
                    backslashEscapes: !rules.sqlQuoting,
                    doubledQuotes: rules.sqlQuoting
                ) != nil else {
                    return issue("\(ch) ile açılan metin kapatılmamış", at: start)
                }
                continue
            }
            switch ch {
            case "(", "[", "{":
                stack.append((ch, start))
            case ")", "]", "}":
                guard let top = stack.last else { return issue("eşleşmeyen \(ch)", at: start) }
                guard top.char == pairs[ch] else {
                    return issue("\(top.char) kapatılmadan \(ch) geldi", at: start)
                }
                stack.removeLast()
            default:
                break
            }
            scanner.index += 1
        }
        if let open = stack.last { return issue("\(open.char) kapatılmamış", at: open.offset) }
        return .structurallyValid
    }
}
