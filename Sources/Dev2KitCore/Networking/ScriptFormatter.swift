import Foundation

/// JavaScript gövdelerini süslü parantez yapısına göre girintiler.
///
/// Tam bir JS parser değildir (Prettier gibi satır genişliğine göre sarma,
/// operatör hizalama yapmaz). String, template literal, yorum ve regex
/// literalleri atomik olarak korunur; girinti `{}` `[]` `()` dengesine göre
/// kurulur. Boş satırlar normalize edilir.
public enum ScriptFormatter {
    static let language = "JavaScript"

    public static func beautify(_ text: String, indent: String = "  ") throws -> String {
        var scanner = CodeScanner(try BeautifyError.requireContent(text, language: language))
        var writer = IndentedWriter(indent: indent)
        var stack: [Character] = []

        /// `/` bu konumda regex başlatıyor mu? Önceki anlamlı karakter bir
        /// değer sonuysa (identifier, sayı, `)`, `]`) bölme operatörüdür.
        var regexAllowed: Bool {
            guard let last = writer.lastMeaningful else { return true }
            return !(last.isLetter || last.isNumber || last == ")" || last == "]" || last == "_" || last == "$")
        }

        while !scanner.isAtEnd {
            let ch = scanner.current

            // Boşluk. Satır sonu içeren boşluk, parantez/köşeli parantez
            // dışında SATIR SONU olarak kalır: noktalı virgülsüz kodda satırları
            // birleştirmek kodu bozuyordu (`let a = 1⏎let b = 2` →
            // `let a = 1 let b = 2`) ve `return⏎x`'in anlamını değiştiriyordu
            // (ASI). Ardışık boş satırlar teke iner.
            if ch.isWhitespace {
                var sawNewline = false
                while !scanner.isAtEnd, scanner.current.isWhitespace {
                    if scanner.current.isNewline { sawNewline = true }
                    scanner.index += 1
                }
                let inParens = stack.last == "(" || stack.last == "[" || stack.last == "<"
                if sawNewline, !inParens, !writer.isEmpty {
                    writer.newline()
                } else {
                    writer.space()
                }
                continue
            }

            if let comment = try scanner.readComment(language: language) {
                writer.comment(comment)
                continue
            }

            // String ve template literal
            if ch == "\"" || ch == "'" || ch == "`" {
                guard let quoted = scanner.readQuoted(multiline: ch == "`") else {
                    throw BeautifyError.invalid(language, L10n.t("beautify.unclosedText", String(ch)))
                }
                writer.append(quoted)
                continue
            }

            // Regex literal (bayraklarıyla: /a/gi)
            if ch == "/", regexAllowed, var literal = scanner.readQuoted(multiline: false) {
                while !scanner.isAtEnd, scanner.current.isLetter {
                    literal.append(scanner.current)
                    scanner.index += 1
                }
                writer.append(literal)
                continue
            }

            switch ch {
            case "{":
                writer.trimTrailing()
                // Boş gövde tek satırda kalsın: {}
                if scanner.nextNonWhitespace(after: scanner.index + 1) == "}" {
                    writer.append(writer.isEmpty ? "{}" : " {}")
                    scanner.index += 1
                    while scanner.current != "}" { scanner.index += 1 }
                    scanner.index += 1
                    continue
                }
                writer.append(writer.isEmpty ? "{" : " {")
                stack.append("{")
                writer.level += 1
                writer.newline()

            case "}":
                while stack.last == "<" { stack.removeLast() }
                guard stack.last == "{" else {
                    throw BeautifyError.invalid(language, L10n.t("beautify.unmatched", "}"))
                }
                stack.removeLast()
                writer.level = max(0, writer.level - 1)
                writer.newline()
                writer.append("}")

            case "(", "[":
                writer.append(String(ch))
                stack.append(ch)

            // TypeScript generic'i: `Map<string, number>`. `<` bir adın HEMEN
            // ardından (boşluksuz) gelip ardından ad/parantez geliyorsa açılış
            // sayılır; içindeki virgül satır kırmaz. Karşılaştırma (`a<b`) yanlışlıkla
            // açılış sayılırsa zararsız: kapanış parantezinde düşürülür.
            case "<":
                writer.append("<")
                let previous = scanner.index > 0 ? scanner.chars[scanner.index - 1] : " "
                let next = scanner.peek() ?? " "
                if previous.isLetter || previous.isNumber || previous == "_" || previous == "$" || previous == ">",
                   next.isLetter || next == "{" || next == "[" || next == "(" || next == "'" || next == "\"" || next == ">" {
                    stack.append("<")
                }

            case ">":
                writer.append(">")
                if stack.last == "<" { stack.removeLast() }

            case ")", "]":
                // Kapatılmamış `<` karşılaştırmaydı, generic değil: düşür.
                while stack.last == "<" { stack.removeLast() }
                let expected: Character = ch == ")" ? "(" : "["
                guard stack.last == expected else {
                    throw BeautifyError.invalid(language, L10n.t("beautify.unmatched", String(ch)))
                }
                stack.removeLast()
                writer.trimTrailing()
                writer.append(String(ch))

            case ";":
                writer.trimTrailing()
                writer.append(";")
                // for(;;) içindeki ; satır sonu yapmamalı.
                if !stack.contains("(") { writer.newline() }

            case ",":
                writer.trimTrailing()
                writer.append(",")
                // Nesne literalinde her alan kendi satırında; dizi ve
                // argüman listeleri satır içinde kalır.
                if stack.last == "{" { writer.newline() } else { writer.append(" ") }

            case ":":
                writer.trimTrailing()
                writer.append(": ")

            default:
                writer.append(String(ch))
            }
            scanner.index += 1
        }

        while stack.last == "<" { stack.removeLast() }
        if let unclosed = stack.last {
            throw BeautifyError.invalid(language, L10n.t("beautify.unclosed", String(unclosed)))
        }
        writer.trimTrailing()
        return writer.text
    }
}
