import Foundation

/// Tam sözdizimi okuyucusu olmayan dillerde (JavaScript, TypeScript, CSS)
/// yapısal kontrol: parantez dengesi, kapanmamış string/yorum/regex. Hata
/// konumuyla döner. Sonuç `.structurallyValid`: arayüz "geçerli" DEMEZ.
///
/// Tarama `CodeScanner` ile (biçimlendiricilerle aynı string/yorum kuralları).
public enum StructureCheck {
    public struct Rules: Sendable {
        let language: String
        let quotes: Set<Character>
        /// Çok satırlı olabilen tırnak (JS template literal).
        let multilineQuote: Character?
        /// `//` satır yorumu var mı (CSS'te yok; `url(http://…)` yorum değil).
        let lineComments: Bool
        let regexLiterals: Bool

        public static let javascript = Rules(language: "JavaScript", quotes: ["\"", "'", "`"], multilineQuote: "`", lineComments: true, regexLiterals: true)
        public static let typescript = Rules(language: "TypeScript", quotes: ["\"", "'", "`"], multilineQuote: "`", lineComments: true, regexLiterals: true)
        public static let css = Rules(language: "CSS", quotes: ["\"", "'"], multilineQuote: nil, lineComments: false, regexLiterals: false)
    }

    public static func validate(_ text: String, rules: Rules) -> WorkbenchValidation {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        var scanner = CodeScanner(text)
        var stack: [(char: Character, offset: Int)] = []
        var lastMeaningful: Character?
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]

        func issue(_ message: String, at offset: Int) -> WorkbenchValidation {
            .invalid(.at(characterOffset: offset, in: scanner.chars, message: "Geçersiz \(rules.language): \(message)"))
        }

        while !scanner.isAtEnd {
            let ch = scanner.current
            let start = scanner.index
            if ch.isWhitespace { scanner.index += 1; continue }
            if ch == "/", let next = scanner.peek(), next == "*" || (next == "/" && rules.lineComments) {
                guard (try? scanner.readComment(language: rules.language)) != nil else {
                    return issue("/* yorumu */ ile kapatılmamış", at: start)
                }
                continue
            }
            if rules.quotes.contains(ch) {
                guard scanner.readQuoted(multiline: ch == rules.multilineQuote) != nil else {
                    return issue("\(ch) ile açılan metin kapatılmamış", at: start)
                }
                lastMeaningful = ch
                continue
            }
            if rules.regexLiterals, ch == "/", regexAllowed(after: lastMeaningful),
               scanner.readQuoted(multiline: false) != nil {
                while !scanner.isAtEnd, scanner.current.isLetter { scanner.index += 1 }
                lastMeaningful = "/"
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
            lastMeaningful = ch
            scanner.index += 1
        }
        if let open = stack.last { return issue("\(open.char) kapatılmamış", at: open.offset) }
        return .structurallyValid
    }

    /// `/` regex mi bölme mi: önceki anlamlı karakter bir değer sonuysa bölme
    /// (`ScriptFormatter` ile aynı kural).
    static func regexAllowed(after last: Character?) -> Bool {
        guard let last else { return true }
        return !(last.isLetter || last.isNumber || last == ")" || last == "]" || last == "_" || last == "$")
    }
}
