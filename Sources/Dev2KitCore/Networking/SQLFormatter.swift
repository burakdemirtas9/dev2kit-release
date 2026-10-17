import Foundation

/// SQL biçimlendirici ve sıkıştırıcı. Ortak parçalar üzerine: `CodeScanner`
/// (tırnak, yorum), `IndentedWriter` (girinti, yorum yerleşimi), `BeautifyError`.
///
/// Biçim (yaygın stil, lehçeden bağımsız):
///
///     SELECT
///       a,
///       b
///     FROM t
///     JOIN u ON u.id = t.u_id
///     WHERE x = 1
///       AND y BETWEEN 1 AND 2
///
/// - Ana cümleler yeni satırda; SELECT/SET/GROUP BY/ORDER BY listesinde her
///   öge kendi satırında. AND/OR yeni satırda; `BETWEEN x AND y`'deki AND bölünmez.
/// - Alt sorgu `(SELECT …)` bir seviye içeride.
/// - String (`'it''s'`, `'C:\'`), tanımlayıcı (`"ad"`, `` `ad` ``, `[ad]`) ve
///   yorum (`--`, `/* */`) içine dokunulmaz. Lehçe bazlı tam doğrulama yok.
public enum SQLFormatter {
    static let language = "SQL"

    /// Büyük harfe çevrilen (ve cümle kuralı taşıyan) anahtar kelimeler.
    static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "IS", "IN", "AS", "ON", "USING",
        "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL",
        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "NEXT", "ROWS", "ROW", "ONLY", "TOP",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "MERGE", "MATCHED", "RETURNING",
        "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "VIEW", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
        "DEFAULT", "UNIQUE", "CHECK", "CONSTRAINT", "ADD", "COLUMN", "IF", "EXISTS",
        "DISTINCT", "UNION", "ALL", "INTERSECT", "EXCEPT", "MINUS",
        "CASE", "WHEN", "THEN", "ELSE", "END", "BETWEEN", "LIKE", "ILIKE", "ASC", "DESC", "WITH", "RECURSIVE",
        "TRUE", "FALSE", "OVER", "PARTITION", "CAST", "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLS",
    ]

    /// Kendi satırında başlayan cümleler.
    private static let clauses: Set<String> = [
        "SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "OFFSET", "FETCH", "VALUES", "SET", "RETURNING",
        "WITH", "UPDATE", "INSERT", "DELETE", "MERGE", "UNION", "INTERSECT", "EXCEPT", "MINUS", "GROUP", "ORDER",
    ]
    /// Ögeleri ayrı satırlarda listelenen cümleler.
    private static let listClauses: Set<String> = ["SELECT", "SET", "GROUP", "ORDER"]
    /// JOIN'i niteleyen sözcükler: `LEFT OUTER JOIN` tek ifade.
    private static let joinModifiers: Set<String> = ["LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL"]

    enum Token: Equatable {
        case word(String)
        case quoted(String)
        case symbol(String)
        case comment(CodeScanner.Comment)
    }

    // MARK: - Biçimlendirme

    public static func beautify(_ text: String, indent: String = "  ", uppercaseKeywords: Bool = true) throws -> String {
        let tokens = try tokenize(try BeautifyError.requireContent(text, language: language))
        var writer = IndentedWriter(indent: indent)
        var base = 0
        var inList = false
        var clause = ""
        var betweenPending = false
        /// Açık parantezler: alt sorgu mu, satır içi mi.
        var parens: [Bool] = []
        var index = 0

        func word(_ value: String) -> String {
            uppercaseKeywords && keywords.contains(value.uppercased()) ? value.uppercased() : value
        }
        func upper(_ offset: Int) -> String? {
            guard index + offset < tokens.count, case .word(let value) = tokens[index + offset] else { return nil }
            return value.uppercased()
        }
        /// Sözcük, önceki öğeye bitişik mi (`a.b`, `f(`, `::int`).
        func appendWord(_ value: String) {
            if let last = writer.text.last, last != "(" && last != "." && !(last == ":" && writer.text.hasSuffix("::")) {
                writer.space()
            }
            writer.append(value)
        }
        func startLine(_ level: Int) {
            writer.level = level
            writer.newline()
        }

        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case .comment(let comment):
                writer.comment(comment)

            case .quoted(let value):
                appendWord(value)

            case .word(let raw):
                let value = raw.uppercased()
                // Cümleler yeni satırda — satır içi parantezde DEĞİL:
                // `OVER (PARTITION BY x ORDER BY y)` bölünmesin.
                if clauses.contains(value), parens.last != false {
                    // `;` sonrası bırakılan boş satır korunur.
                    if !writer.isEmpty, !writer.text.hasSuffix("\n\n") { startLine(base) }
                    var phrase = word(raw)
                    // İki sözcüklü cümleler: GROUP BY, ORDER BY, INSERT INTO, DELETE FROM, UNION ALL.
                    if ["GROUP", "ORDER"].contains(value), upper(1) == "BY" {
                        phrase += " " + word("BY"); index += 1
                    } else if (value == "INSERT" && upper(1) == "INTO") || (value == "DELETE" && upper(1) == "FROM") {
                        if case .word(let next) = tokens[index + 1] { phrase += " " + word(next) }
                        index += 1
                    } else if ["UNION", "INTERSECT", "EXCEPT"].contains(value), upper(1) == "ALL" || upper(1) == "DISTINCT" {
                        if case .word(let next) = tokens[index + 1] { phrase += " " + word(next) }
                        index += 1
                    } else if value == "SELECT", upper(1) == "DISTINCT" || upper(1) == "TOP" {
                        if case .word(let next) = tokens[index + 1] { phrase += " " + word(next) }
                        index += 1
                    }
                    writer.append(phrase)
                    clause = value
                    inList = listClauses.contains(value)
                    if inList {
                        startLine(base + 1)
                    } else if ["UNION", "INTERSECT", "EXCEPT", "MINUS"].contains(value) {
                        startLine(base)
                    }
                } else if value == "JOIN" || joinModifiers.contains(value) && (1...2).contains(where: { upper($0) == "JOIN" }) {
                    // `LEFT OUTER JOIN` → tek satır başı.
                    startLine(base)
                    var phrase = word(raw)
                    while value != "JOIN", let next = upper(1) {
                        phrase += " " + word(next)
                        index += 1
                        if next == "JOIN" { break }
                    }
                    writer.append(phrase)
                    clause = "JOIN"
                    inList = false
                } else if (value == "AND" || value == "OR") && !betweenPending
                            && parens.last != false && ["WHERE", "HAVING", "JOIN", "ON"].contains(clause) {
                    startLine(base + 1)
                    writer.append(word(raw))
                } else {
                    if value == "AND" { betweenPending = false }
                    if value == "BETWEEN" { betweenPending = true }
                    if value == "ON" { clause = "ON" }
                    appendWord(word(raw))
                }

            case .symbol(let symbol):
                switch symbol {
                case ",":
                    writer.trimTrailing()
                    writer.append(",")
                    if inList && parens.last != false { startLine(base + 1) } else { writer.append(" ") }
                case "(":
                    let isSubquery = upper(1) == "SELECT" || upper(1) == "WITH"
                    if let last = writer.text.last, last != "(" && !last.isLetter && !last.isNumber && last != "_" && last != "\"" && last != "`" && last != "]" {
                        writer.space()
                    } else if let last = writer.text.last, last.isLetter, clause != "" {
                        // `IN (`, `EXISTS (` gibi anahtar kelimeden sonra boşluk; fonksiyon çağrısında değil.
                        let lastWord = writer.text.reversed().prefix { $0.isLetter }
                        if keywords.contains(String(lastWord.reversed()).uppercased()) && !["COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "CAST"].contains(String(lastWord.reversed()).uppercased()) {
                            writer.space()
                        }
                    }
                    writer.append("(")
                    parens.append(isSubquery)
                    if isSubquery {
                        base += 1
                        startLine(base)
                    }
                case ")":
                    let wasSubquery = parens.popLast() ?? false
                    writer.trimTrailing()
                    if wasSubquery {
                        base = max(0, base - 1)
                        startLine(base)
                        inList = false
                    }
                    writer.append(")")
                case ";":
                    writer.trimTrailing()
                    writer.append(";")
                    base = 0
                    parens.removeAll()
                    inList = false
                    clause = ""
                    if index + 1 < tokens.count { writer.blankLine() }
                case ".", "::":
                    writer.trimTrailing()
                    writer.append(symbol)
                case "*" where isWildcardPosition(writer.text):
                    // Joker (`SELECT *`, `COUNT(*)`, `t.*`), çarpma değil: boşluksuz.
                    if writer.text.last == "(" || writer.text.last == "." { writer.append("*") } else { appendWord("*") }
                default:
                    // Operatörler: çevresinde birer boşluk.
                    writer.space()
                    writer.append(symbol)
                    writer.space()
                }
            }
            index += 1
        }
        guard parens.isEmpty else { throw BeautifyError.invalid(language, "( kapatılmamış.") }
        writer.trimTrailing()
        return writer.text
    }

    /// `*` joker mi (çarpma değil): metnin başında, satır başında, `(` ya da
    /// `.` hemen ardından.
    static func isWildcardPosition(_ text: String) -> Bool {
        guard let last = text.last else { return true }
        if last == "(" || last == "." { return true }
        let currentLine = text.reversed().prefix { !$0.isNewline }
        return currentLine.allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - Sıkıştırma

    /// Tek satır: yorumlar atılır, boşluk teke iner, noktalama çevresindeki
    /// boşluk düşer; string ve tanımlayıcı içine dokunulmaz.
    public static func minify(_ text: String) throws -> String {
        let tokens = try tokenize(try BeautifyError.requireContent(text, language: language))
        var out = ""
        let tight: Set<String> = ["(", ")", ",", ";", ".", "::", "=", "<", ">", "<=", ">=", "<>", "!=", "+", "-", "*", "/", "%", "||"]
        var previousTight = true
        for token in tokens {
            switch token {
            case .comment:
                continue
            case .symbol(let symbol):
                out += symbol
                previousTight = tight.contains(symbol)
            case .word(let value), .quoted(let value):
                if !previousTight { out += " " }
                out += value
                previousTight = false
            }
        }
        return out
    }

    // MARK: - Tarama

    static func tokenize(_ text: String) throws -> [Token] {
        var scanner = CodeScanner(text)
        var tokens: [Token] = []
        while !scanner.isAtEnd {
            let ch = scanner.current
            if ch.isWhitespace { scanner.index += 1; continue }
            // Satır yorumu `--`; CodeScanner'ınki `//` olduğu için burada.
            if ch == "-", scanner.peek() == "-" {
                let isTrailing = !scanner.startsLine(at: scanner.index)
                var end = scanner.index
                while end < scanner.chars.count, !scanner.chars[end].isNewline { end += 1 }
                let comment = String(scanner.chars[scanner.index..<end]).trimmingCharacters(in: .whitespaces)
                tokens.append(.comment(.init(text: comment, style: .line, isTrailing: isTrailing)))
                scanner.index = end
                continue
            }
            if ch == "/", scanner.peek() == "*", let comment = try scanner.readComment(language: language) {
                tokens.append(.comment(comment))
                continue
            }
            if ch == "'" || ch == "\"" || ch == "`" || ch == "[" {
                guard let quoted = scanner.readQuoted(
                    multiline: true,
                    closing: ch == "[" ? "]" : nil,
                    backslashEscapes: false,
                    doubledQuotes: ch != "["
                ) else {
                    throw BeautifyError.invalid(language, "\(ch) ile açılan metin kapatılmamış.")
                }
                tokens.append(.quoted(quoted))
                continue
            }
            if isWordCharacter(ch) || ((ch == ":" || ch == "@" || ch == "$") && scanner.peek().map(isWordCharacter) == true && !(ch == ":" && scanner.peek() == ":")) {
                // Ad, sayı, bağlama parametresi (`:id`, `@p`, `$1`).
                var end = scanner.index + 1
                while end < scanner.chars.count, isWordCharacter(scanner.chars[end]) { end += 1 }
                tokens.append(.word(String(scanner.chars[scanner.index..<end])))
                scanner.index = end
                continue
            }
            if let operatorText = ["::", "<=", ">=", "<>", "!=", "||"].first(where: { scanner.hasPrefix($0) }) {
                tokens.append(.symbol(operatorText))
                scanner.index += operatorText.count
                continue
            }
            tokens.append(.symbol(String(ch)))
            scanner.index += 1
        }
        return tokens
    }

    private static func isWordCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "#"
    }
}
