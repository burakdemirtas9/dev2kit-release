import Foundation

/// JavaScript/TypeScript sıkıştırma kuralı (CSS'inki `CSSFormatter`'da).
public enum ScriptTools {
    // MARK: - Güvenli sıkıştırma

    /// Yalnızca güvenli küçültme: yorumlar ve gereksiz boşluk atılır, ad
    /// kısaltma YOK. Satır sonları, noktalı virgülsüz kodda anlam taşıdığı
    /// için (ASI: `return⏎x`) yalnızca `{ ; ,` sonrasında ve `}` öncesinde
    /// düşer. Noktalama çevresindeki boşluk düşer; `a + +b` gibi operatör
    /// çiftlerine dokunulmaz.
    public static func minifyJavaScript(_ text: String, language: String = "JavaScript") throws -> String {
        var scanner = CodeScanner(try BeautifyError.requireContent(text, language: language))
        var out = ""
        var pending: Character?  // " " ya da "\n"
        var lastMeaningful: Character?
        let tight: Set<Character> = ["{", "}", "(", ")", "[", "]", ";", ",", ":", "="]
        let breakFree: Set<Character> = ["{", ";", ","]

        func emit(_ piece: String) {
            guard let first = piece.first else { return }
            if let gap = pending, let last = out.last {
                if gap == "\n" {
                    if !breakFree.contains(last) && first != "}" { out.append("\n") }
                    else if !tight.contains(last) && !tight.contains(first) { out.append(" ") }
                } else if !tight.contains(last) && !tight.contains(first) {
                    out.append(" ")
                }
            }
            pending = nil
            out += piece
            if let meaningful = piece.last { lastMeaningful = meaningful }
        }

        while !scanner.isAtEnd {
            let ch = scanner.current
            if ch.isWhitespace {
                if ch.isNewline { pending = "\n" } else if pending == nil { pending = " " }
                scanner.index += 1
                continue
            }
            if ch == "/", let next = scanner.peek(), next == "/" || next == "*" {
                let comment = try scanner.readComment(language: language)
                // Satır yorumu satır sonuyla biter; o satır sonu korunur.
                if comment?.style == .line, pending == nil { pending = "\n" }
                continue
            }
            if ch == "\"" || ch == "'" || ch == "`" {
                guard let quoted = scanner.readQuoted(multiline: ch == "`") else {
                    throw BeautifyError.invalid(language, "\(ch) ile açılan metin kapatılmamış.")
                }
                emit(quoted)
                continue
            }
            if ch == "/", StructureCheck.regexAllowed(after: lastMeaningful), var literal = scanner.readQuoted(multiline: false) {
                while !scanner.isAtEnd, scanner.current.isLetter {
                    literal.append(scanner.current)
                    scanner.index += 1
                }
                emit(literal)
                continue
            }
            emit(String(ch))
            scanner.index += 1
        }
        return out
    }
}
