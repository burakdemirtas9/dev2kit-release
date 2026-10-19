import Foundation

/// YAML okuyucu: Spring `application.yml` dosyalarının kullandığı alt küme
/// (2026-10-20, YAML → Properties için; step 3'ün YAML okuyucusu).
///
/// Desteklenen: blok eşlemeler ve diziler (`key:` altında aynı girintide
/// `- ` dahil), düz / tek tırnaklı / çift tırnaklı değerler, çok satırlı `|` ve
/// `>` (`-`/`+` ekleriyle), tek satırlık akış biçimi (`[a, b]`, `{a: 1}`),
/// yorumlar, `---` ile ayrılmış belgeler.
///
/// Bilerek REDDEDİLEN (açık hatayla): çapa/takma ad (`&a`, `*a`, `<<`) —
/// takma ad açılımı "billion laughs" bellek patlamasına açık; etiketler
/// (`!!str`, `!Tip`) — bazı okuyucularda nesne kurdurur; girintide sekme
/// (YAML'da geçersiz); yinelenen anahtar (Spring'in SnakeYAML ayarı da reddeder).
///
/// Değer tipleri YAML 1.2 temel şemasıyla: `null`/`~`/boş → null,
/// `true`/`false` → bool, sayılar → sayı (YAZILDIĞI GİBİ korunur), kalanı metin.
public enum YAMLReader {
    public static let maxDepth = 128

    /// Her `---` belgesi ayrı değer.
    public static func documents(_ input: String) throws -> [JSONValue] {
        var parser = Parser(lines: try Line.split(input))
        return try parser.documents()
    }

    public static func validate(_ input: String) -> WorkbenchValidation {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        do {
            _ = try documents(input)
            return .valid
        } catch let issue as WorkbenchIssue {
            return .invalid(issue)
        } catch {
            return .invalid(WorkbenchIssue(message: error.localizedDescription))
        }
    }

    // MARK: - Satırlar

    struct Line {
        let number: Int
        let indent: Int
        /// Girintisiz, yorumu atılmış, sondaki boşlukları kırpılmış içerik.
        let text: String
        /// Ham satır (çok satırlı `|`/`>` için).
        let raw: String
        var isBlank: Bool { text.isEmpty }

        static func split(_ input: String) throws -> [Line] {
            var text = input
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            return try rawLines.enumerated().map { offset, raw in
                let raw = String(raw)
                let indent = raw.prefix { $0 == " " }.count
                let rest = raw.dropFirst(indent)
                if rest.first == "\t", !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw WorkbenchIssue(message: "Girintide sekme var: YAML'da girinti yalnızca boşlukla yapılır.",
                                         line: offset + 1, column: indent + 1)
                }
                return Line(number: offset + 1, indent: indent, text: stripComment(String(rest)), raw: raw)
            }
        }

        /// `#` yorumu: satır başında ya da boşluktan sonra, tırnak dışında.
        static func stripComment(_ text: String) -> String {
            var inSingle = false
            var inDouble = false
            var previous: Character = " "
            var escaped = false
            var end = text.endIndex
            for index in text.indices {
                let character = text[index]
                if inDouble {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inDouble = false }
                } else if inSingle {
                    if character == "'" { inSingle = false }
                } else if character == "\"" {
                    inDouble = true
                } else if character == "'" {
                    inSingle = true
                } else if character == "#", previous == " " || previous == "\t" {
                    end = index
                    break
                }
                previous = character
            }
            return String(text[..<end]).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Ayrıştırıcı

    struct Parser {
        var lines: [Line]
        var position = 0

        init(lines: [Line]) { self.lines = lines }

        mutating func documents() throws -> [JSONValue] {
            var result: [JSONValue] = []
            while true {
                skipBlank()
                guard position < lines.count else { break }
                let line = lines[position]
                if line.indent == 0, line.text == "---" || line.text.hasPrefix("--- ") {
                    if line.text != "---" {
                        throw issue("`---` satırında içerik desteklenmiyor; değeri alt satıra yaz.", line)
                    }
                    position += 1
                    continue
                }
                if line.indent == 0, line.text == "..." { position += 1; continue }
                let value = try node(minIndent: 0, depth: 0)
                result.append(value)
                skipBlank()
                if position < lines.count {
                    let next = lines[position]
                    if !(next.indent == 0 && (next.text == "---" || next.text == "...")) {
                        throw issue("Beklenmeyen girinti ya da içerik.", next)
                    }
                }
            }
            return result
        }

        mutating func skipBlank() {
            while position < lines.count, lines[position].isBlank { position += 1 }
        }

        func issue(_ message: String, _ line: Line, column: Int? = nil) -> WorkbenchIssue {
            WorkbenchIssue(message: message, line: line.number, column: column ?? line.indent + 1)
        }

        /// Geçerli satırdan başlayan düğüm (girintisi `minIndent` ya da fazlası).
        mutating func node(minIndent: Int, depth: Int) throws -> JSONValue {
            guard depth <= YAMLReader.maxDepth else {
                throw issue("İç içe derinlik \(YAMLReader.maxDepth)'i aşıyor.", lines[min(position, lines.count - 1)])
            }
            skipBlank()
            guard position < lines.count, lines[position].indent >= minIndent, !isDocumentMarker(lines[position]) else { return .null }
            let line = lines[position]
            if isSequenceItem(line.text) { return try sequence(indent: line.indent, depth: depth) }
            if try splitKey(line.text, line: line) != nil { return try mapping(indent: line.indent, depth: depth) }
            position += 1
            return try scalarValue(line.text, line: line, parentIndent: line.indent - 1, depth: depth)
        }

        func isSequenceItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

        /// `---` / `...`: belge sınırı; içteki blok burada biter.
        func isDocumentMarker(_ line: Line) -> Bool {
            line.indent == 0 && (line.text == "---" || line.text.hasPrefix("--- ") || line.text == "...")
        }

        mutating func sequence(indent: Int, depth: Int) throws -> JSONValue {
            var items: [JSONValue] = []
            while true {
                skipBlank()
                guard position < lines.count else { break }
                let line = lines[position]
                if isDocumentMarker(line) { break }
                guard line.indent == indent, isSequenceItem(line.text) else {
                    if line.indent > indent { throw issue("Beklenmeyen girinti.", line) }
                    break
                }
                let rest = line.text.dropFirst(1)
                let content = rest.drop { $0 == " " }
                if content.isEmpty {
                    position += 1
                    items.append(try nested(after: indent, depth: depth))
                } else {
                    // "- a: 1" — öğenin içeriği, kendi sütununda başlayan bir satır gibi.
                    let column = indent + 1 + (rest.count - content.count)
                    lines[position] = Line(number: line.number, indent: column, text: String(content), raw: line.raw)
                    items.append(try node(minIndent: column, depth: depth + 1))
                }
            }
            return .array(items)
        }

        /// `key:` / `-` sonrası boş değer: altındaki daha girintili blok ya da null.
        mutating func nested(after indent: Int, depth: Int, allowCompactSequence: Bool = false) throws -> JSONValue {
            skipBlank()
            guard position < lines.count else { return .null }
            let next = lines[position]
            if isDocumentMarker(next) { return .null }
            if next.indent > indent { return try node(minIndent: next.indent, depth: depth + 1) }
            if allowCompactSequence, next.indent == indent, isSequenceItem(next.text) {
                return try sequence(indent: indent, depth: depth + 1)
            }
            return .null
        }

        mutating func mapping(indent: Int, depth: Int) throws -> JSONValue {
            var members: [(key: String, value: JSONValue)] = []
            var seen: Set<String> = []
            while true {
                skipBlank()
                guard position < lines.count else { break }
                let line = lines[position]
                if isDocumentMarker(line) { break }
                guard line.indent == indent else {
                    if line.indent > indent { throw issue("Beklenmeyen girinti.", line) }
                    break
                }
                guard let (key, valueText) = try splitKey(line.text, line: line) else {
                    if isSequenceItem(line.text) { throw issue("Eşlemenin içinde beklenmeyen liste öğesi; girintiyi kontrol et.", line) }
                    throw issue("`anahtar: değer` bekleniyordu.", line)
                }
                if key == "<<" { throw issue("Birleştirme anahtarı (`<<`) desteklenmiyor.", line) }
                guard seen.insert(key).inserted else { throw issue("Yinelenen anahtar: \(key)", line) }
                position += 1
                let value: JSONValue
                if valueText.isEmpty {
                    value = try nested(after: indent, depth: depth, allowCompactSequence: true)
                } else {
                    value = try scalarValue(valueText, line: line, parentIndent: indent, depth: depth)
                }
                members.append((key, value))
            }
            return .object(members)
        }

        /// `anahtar: değer` ayrımı (tırnak ve akış parantezleri dışındaki ilk
        /// `: ` ya da sondaki `:`). Eşleme satırı değilse nil.
        func splitKey(_ text: String, line: Line) throws -> (String, String)? {
            if isSequenceItem(text) { return nil }
            if text.hasPrefix("? ") { throw issue("Karmaşık anahtar (`? `) desteklenmiyor.", line) }
            var keyEnd: String.Index?
            if let first = text.first, first == "\"" || first == "'" {
                guard let close = closingQuote(in: text, quote: first) else { return nil }
                let after = text.index(after: close)
                guard after < text.endIndex, text[after] == ":" else { return nil }
                let next = text.index(after: after)
                guard next == text.endIndex || text[next] == " " else { return nil }
                keyEnd = after
            } else {
                if let first = text.first, first == "[" || first == "{" { return nil }
                var index = text.startIndex
                while index < text.endIndex {
                    if text[index] == ":" {
                        let next = text.index(after: index)
                        if next == text.endIndex || text[next] == " " { keyEnd = index; break }
                    }
                    index = text.index(after: index)
                }
            }
            guard let keyEnd else { return nil }
            let rawKey = String(text[..<keyEnd]).trimmingCharacters(in: .whitespaces)
            let value = String(text[text.index(after: keyEnd)...]).trimmingCharacters(in: .whitespaces)
            let key: String
            if let first = rawKey.first, first == "\"" || first == "'" {
                key = try quoted(rawKey, line: line)
            } else {
                if rawKey.hasPrefix("&") || rawKey.hasPrefix("*") || rawKey.hasPrefix("!") {
                    throw issue("Çapa, takma ad ve etiket desteklenmiyor.", line)
                }
                key = rawKey
            }
            return (key, value)
        }

        func closingQuote(in text: String, quote: Character) -> String.Index? {
            var index = text.index(after: text.startIndex)
            while index < text.endIndex {
                let character = text[index]
                if quote == "\"", character == "\\" {
                    index = text.index(after: index)
                    if index < text.endIndex { index = text.index(after: index) }
                    continue
                }
                if character == quote {
                    if quote == "'" {
                        let next = text.index(after: index)
                        if next < text.endIndex, text[next] == "'" { index = text.index(after: next); continue }
                    }
                    return index
                }
                index = text.index(after: index)
            }
            return nil
        }

        /// Satırdaki değer (anahtardan sonra ya da tek başına).
        mutating func scalarValue(_ text: String, line: Line, parentIndent: Int, depth: Int) throws -> JSONValue {
            guard let first = text.first else { return .null }
            switch first {
            case "&", "*":
                throw issue("Çapa ve takma ad (`&`, `*`) desteklenmiyor: güvenlik için açılmıyor.", line)
            case "!":
                throw issue("Etiketler (`!!str`, `!Tip`) desteklenmiyor.", line)
            case "|", ">":
                return .string(try blockScalar(header: text, folded: first == ">", parentIndent: parentIndent, line: line))
            case "[", "{":
                var flow = FlowParser(text: text, line: line, depth: depth)
                return try flow.parseAll()
            case "\"", "'":
                var full = text
                // Kapanmamış tırnak: sonraki satırlarla katlanarak devam eder.
                while closingQuote(in: full, quote: first) == nil {
                    guard position < lines.count else { throw issue("Tırnak kapanmamış.", line) }
                    let next = lines[position].raw.trimmingCharacters(in: .whitespaces)
                    position += 1
                    full += next.isEmpty ? "\n" : " " + next
                }
                guard let close = closingQuote(in: full, quote: first) else { throw issue("Tırnak kapanmamış.", line) }
                let tail = full[full.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { throw issue("Tırnaktan sonra beklenmeyen içerik.", line) }
                return .string(try quoted(String(full[...close]), line: line))
            default:
                // Çok satırlı düz değer: daha girintili devam satırları boşlukla katlanır.
                var parts = [text]
                while position < lines.count, !lines[position].isBlank, lines[position].indent > parentIndent,
                      !isSequenceItem(lines[position].text), (try? splitKey(lines[position].text, line: lines[position])) == nil {
                    parts.append(lines[position].text)
                    position += 1
                }
                return Self.resolvePlain(parts.joined(separator: " "))
            }
        }

        mutating func blockScalar(header: String, folded: Bool, parentIndent: Int, line: Line) throws -> String {
            var chomp: Character = " "
            var explicitIndent: Int?
            for character in header.dropFirst() {
                if character == "-" || character == "+" { chomp = character }
                else if let digit = character.wholeNumberValue, digit > 0 { explicitIndent = digit }
                else if character != " " { throw issue("Geçersiz `|`/`>` başlığı.", line) }
            }
            var collected: [String] = []
            var blockIndent: Int? = explicitIndent.map { parentIndent + $0 }
            while position < lines.count {
                let raw = lines[position].raw
                let indent = raw.prefix { $0 == " " }.count
                let isBlank = raw.trimmingCharacters(in: .whitespaces).isEmpty
                if isBlank { collected.append(""); position += 1; continue }
                if blockIndent == nil {
                    guard indent > max(parentIndent, 0) || (parentIndent < 0 && indent >= 0) else { break }
                    blockIndent = indent
                }
                guard let block = blockIndent, indent >= block else { break }
                collected.append(String(raw.dropFirst(block)))
                position += 1
            }
            // Sondaki boş satırlar chomping kuralına göre.
            var trailing = 0
            while let last = collected.last, last.isEmpty { collected.removeLast(); trailing += 1 }
            var body: String
            if folded {
                body = ""
                // Katlama: art arda iki dolu satır boşlukla birleşir; her boş
                // satır bir satır sonu olur; fazla girintili satır olduğu gibi.
                for (index, part) in collected.enumerated() {
                    if index == 0 { body = part; continue }
                    let previous = collected[index - 1]
                    if part.isEmpty { body += "\n" }
                    else if previous.isEmpty { body += part }
                    else if part.hasPrefix(" ") || previous.hasPrefix(" ") { body += "\n" + part }
                    else { body += " " + part }
                }
            } else {
                body = collected.joined(separator: "\n")
            }
            if collected.isEmpty { return chomp == "+" ? String(repeating: "\n", count: trailing) : "" }
            switch chomp {
            case "-": return body
            case "+": return body + "\n" + String(repeating: "\n", count: trailing)
            default: return body + "\n"
            }
        }

        func quoted(_ text: String, line: Line) throws -> String {
            guard let quote = text.first, text.count >= 2, text.last == quote else { throw issue("Tırnak kapanmamış.", line) }
            let inner = text.dropFirst().dropLast()
            if quote == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
            var out = ""
            var iterator = inner.makeIterator()
            while let character = iterator.next() {
                guard character == "\\" else { out.append(character); continue }
                guard let escape = iterator.next() else { throw issue("Yarım kaçış dizisi.", line) }
                switch escape {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                case "\"", "\\", "/", " ": out.append(escape)
                case "x", "u", "U":
                    let count = escape == "x" ? 2 : (escape == "u" ? 4 : 8)
                    var hex = ""
                    for _ in 0..<count { if let next = iterator.next() { hex.append(next) } }
                    guard hex.count == count, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
                        throw issue("Geçersiz kaçış: \\\(escape)\(hex)", line)
                    }
                    out.unicodeScalars.append(scalar)
                default:
                    throw issue("Bilinmeyen kaçış: \\\(escape)", line)
                }
            }
            return out
        }

        /// YAML 1.2 temel şeması; sayı yazıldığı gibi korunur.
        static func resolvePlain(_ text: String) -> JSONValue {
            switch text {
            case "", "~", "null", "Null", "NULL": return .null
            case "true", "True", "TRUE": return .bool(true)
            case "false", "False", "FALSE": return .bool(false)
            default: break
            }
            if text.range(of: #"^[-+]?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil
                || text.range(of: #"^[-+]?(\.[0-9]+|[0-9]+\.[0-9]*)([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil
                || text.range(of: #"^[-+]?[0-9]+[eE][-+]?[0-9]+$"#, options: .regularExpression) != nil {
                return .number(text)
            }
            return .string(text)
        }
    }

    /// Tek satırlık akış biçimi: `[a, "b", {c: 1}]`.
    struct FlowParser {
        let characters: [Character]
        let line: Line
        let depth: Int
        var index = 0

        init(text: String, line: Line, depth: Int) {
            self.characters = Array(text)
            self.line = line
            self.depth = depth
        }

        func issue(_ message: String) -> WorkbenchIssue {
            WorkbenchIssue(message: message, line: line.number, column: line.indent + index + 1)
        }

        mutating func parseAll() throws -> JSONValue {
            let value = try parse(depth: depth)
            skipSpaces()
            guard index == characters.count else { throw issue("Akış biçiminden sonra beklenmeyen içerik (çok satırlı akış desteklenmiyor).") }
            return value
        }

        mutating func skipSpaces() { while index < characters.count, characters[index] == " " { index += 1 } }

        mutating func parse(depth: Int) throws -> JSONValue {
            guard depth <= YAMLReader.maxDepth else { throw issue("İç içe derinlik \(YAMLReader.maxDepth)'i aşıyor.") }
            skipSpaces()
            guard index < characters.count else { throw issue("Akış biçimi yarım kaldı (çok satırlı akış desteklenmiyor).") }
            switch characters[index] {
            case "[":
                index += 1
                var items: [JSONValue] = []
                skipSpaces()
                if index < characters.count, characters[index] == "]" { index += 1; return .array([]) }
                while true {
                    items.append(try parse(depth: depth + 1))
                    skipSpaces()
                    guard index < characters.count else { throw issue("`]` eksik.") }
                    if characters[index] == "," { index += 1; skipSpaces(); if index < characters.count, characters[index] == "]" { index += 1; break }; continue }
                    if characters[index] == "]" { index += 1; break }
                    throw issue("`,` ya da `]` bekleniyordu.")
                }
                return .array(items)
            case "{":
                index += 1
                var members: [(key: String, value: JSONValue)] = []
                var seen: Set<String> = []
                skipSpaces()
                if index < characters.count, characters[index] == "}" { index += 1; return .object([]) }
                while true {
                    let keyValue = try parse(depth: depth + 1)
                    let key: String
                    switch keyValue {
                    case .string(let text), .number(let text): key = text
                    case .bool(let flag): key = flag ? "true" : "false"
                    case .null: key = "null"
                    default: throw issue("Akış eşlemesinde anahtar metin olmalı.")
                    }
                    skipSpaces()
                    var value = JSONValue.null
                    if index < characters.count, characters[index] == ":" {
                        index += 1
                        value = try parse(depth: depth + 1)
                    }
                    guard seen.insert(key).inserted else { throw issue("Yinelenen anahtar: \(key)") }
                    members.append((key, value))
                    skipSpaces()
                    guard index < characters.count else { throw issue("`}` eksik.") }
                    if characters[index] == "," { index += 1; skipSpaces(); if index < characters.count, characters[index] == "}" { index += 1; break }; continue }
                    if characters[index] == "}" { index += 1; break }
                    throw issue("`,` ya da `}` bekleniyordu.")
                }
                return .object(members)
            case "\"", "'":
                let quote = characters[index]
                var end = index + 1
                while end < characters.count {
                    if quote == "\"", characters[end] == "\\" { end += 2; continue }
                    if characters[end] == quote {
                        if quote == "'", end + 1 < characters.count, characters[end + 1] == "'" { end += 2; continue }
                        break
                    }
                    end += 1
                }
                guard end < characters.count else { throw issue("Tırnak kapanmamış.") }
                let raw = String(characters[index...end])
                index = end + 1
                return .string(try Parser(lines: []).quoted(raw, line: line))
            case "&", "*", "!":
                throw issue("Çapa, takma ad ve etiket desteklenmiyor.")
            default:
                var end = index
                while end < characters.count {
                    let character = characters[end]
                    if character == "," || character == "]" || character == "}" { break }
                    if character == ":", end + 1 >= characters.count || characters[end + 1] == " " { break }
                    end += 1
                }
                let text = String(characters[index..<end]).trimmingCharacters(in: .whitespaces)
                index = end
                return Parser.resolvePlain(text)
            }
        }
    }
}
