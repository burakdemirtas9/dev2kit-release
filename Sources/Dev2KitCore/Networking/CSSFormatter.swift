import Foundation

/// CSS biçimlendirici ve sıkıştırıcı. Ortak parçalar üzerine:
/// `CodeScanner` (string, yorum), `IndentedWriter` (girinti, yorum yerleşimi),
/// `BeautifyError`.
///
/// Kural: iki nokta üst üste yalnızca BİLDİRİMDE (`color: red`) boşluk alır;
/// seçicide (`a:hover`, `div :hover`) olduğu gibi kalır — seçicideki boşluk
/// anlamı değiştirir (`div :hover` torun, `div:hover` kendisi). Bir ifadenin
/// bildirim mi seçici mi olduğu, ardından ilk gelen `{`, `;` ya da `}`'ye
/// bakılarak anlaşılır.
public enum CSSFormatter {
    static let language = "CSS"

    public static func beautify(_ text: String, indent: String = "  ") throws -> String {
        var scanner = CodeScanner(try BeautifyError.requireContent(text, language: language))
        var writer = IndentedWriter(indent: indent)
        var depth = 0
        var parens = 0

        while !scanner.isAtEnd {
            let ch = scanner.current
            if ch.isWhitespace {
                if parens > 0 || !atLineStart(writer) { writer.space() }
                scanner.index += 1
                continue
            }
            if let comment = try readComment(&scanner) {
                writer.comment(comment)
                continue
            }
            if ch == "\"" || ch == "'" {
                guard let quoted = scanner.readQuoted(multiline: false) else {
                    throw BeautifyError.invalid(language, "\(ch) ile açılan metin kapatılmamış.")
                }
                writer.append(quoted)
                continue
            }
            switch ch {
            case "{":
                writer.trimTrailing()
                writer.append(writer.isEmpty ? "{" : " {")
                depth += 1
                writer.level = depth
                writer.newline()
            case "}":
                guard depth > 0 else { throw BeautifyError.invalid(language, "eşleşmeyen } karakteri.") }
                depth -= 1
                writer.level = depth
                writer.newline()
                writer.append("}")
                // Kurallar arasında boş satır: okunurluk (Prettier gibi).
                writer.newline()
                if depth == 0, scanner.nextNonWhitespace(after: scanner.index + 1) != nil { writer.blankLine() }
            case ";":
                writer.trimTrailing()
                writer.append(";")
                if parens == 0 { writer.newline() }
            case "(":
                parens += 1
                writer.append("(")
            case ")":
                parens = max(0, parens - 1)
                writer.trimTrailing()
                writer.append(")")
            case ":" where depth > 0 && parens == 0 && isDeclaration(scanner):
                writer.trimTrailing()
                writer.append(": ")
            case ",":
                writer.trimTrailing()
                writer.append(", ")
            default:
                writer.append(String(ch))
            }
            scanner.index += 1
        }
        guard depth == 0 else { throw BeautifyError.invalid(language, "{ kapatılmamış.") }
        writer.trimTrailing()
        return writer.text
    }

    /// Tek satır: yorumlar ve gereksiz boşluk atılır; seçicilerdeki anlamlı
    /// boşluk (`div :hover`, `a b`) korunur, son `;` düşer.
    public static func minify(_ text: String) throws -> String {
        var scanner = CodeScanner(try BeautifyError.requireContent(text, language: language))
        var out = ""
        var pendingSpace = false
        let tight: Set<Character> = ["{", "}", ";", ",", ">", "+", "~"]
        func lastIsTight() -> Bool { out.last.map { tight.contains($0) || $0 == "(" } ?? true }

        while !scanner.isAtEnd {
            let ch = scanner.current
            if ch.isWhitespace {
                pendingSpace = true
                scanner.index += 1
                continue
            }
            if try readComment(&scanner) != nil { continue }
            if ch == "\"" || ch == "'" {
                guard let quoted = scanner.readQuoted(multiline: false) else {
                    throw BeautifyError.invalid(language, "\(ch) ile açılan metin kapatılmamış.")
                }
                if pendingSpace && !lastIsTight() && out.last != ":" { out.append(" ") }
                pendingSpace = false
                out += quoted
                continue
            }
            if tight.contains(ch) || ch == ")" {
                if ch == "}", out.last == ";" { out.removeLast() }
                out.append(ch)
            } else if ch == ":" {
                // Bildirimde `color:red`; seçicide önceki boşluk anlamlı (`div :hover`).
                if pendingSpace && !lastIsTight() && !isDeclaration(scanner) { out.append(" ") }
                out.append(":")
            } else {
                if pendingSpace && !lastIsTight() && out.last != ":" { out.append(" ") }
                out.append(ch)
            }
            pendingSpace = false
            scanner.index += 1
        }
        return out
    }

    /// CSS'te yalnızca `/* */` yorumu var; `//` URL'lerde (`url(http://…)`) geçer.
    private static func readComment(_ scanner: inout CodeScanner) throws -> CodeScanner.Comment? {
        guard scanner.current == "/", scanner.peek() == "*" else { return nil }
        return try scanner.readComment(language: language)
    }

    private static func atLineStart(_ writer: IndentedWriter) -> Bool {
        guard let last = writer.text.last else { return true }
        return last == "\n" || last == " " || last == "\t"
    }

    /// Konumdaki `:` bir bildirime mi ait: ardından `{`'den önce `;` ya da
    /// `}` geliyorsa (ya da metin bitiyorsa) evet.
    static func isDeclaration(_ scanner: CodeScanner) -> Bool {
        var probe = scanner
        probe.index += 1
        while !probe.isAtEnd {
            let ch = probe.current
            if ch == "\"" || ch == "'" {
                if probe.readQuoted(multiline: false) == nil { return true }
                continue
            }
            if ch == "/", probe.peek() == "*" {
                if (try? probe.readComment(language: language)) == nil { return true }
                continue
            }
            if ch == "{" { return false }
            if ch == ";" || ch == "}" { return true }
            probe.index += 1
        }
        return true
    }
}
