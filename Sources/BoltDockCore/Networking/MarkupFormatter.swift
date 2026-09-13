import Foundation

/// XML ve HTML gövdelerini girintiler.
///
/// Etiket yapısını kendi tarayıcısıyla çözer; `XMLDocument` kullanılmadı çünkü
/// o, HTML'in gevşek yapısını (kapatılmayan `<li>`, void elementler) reddediyor
/// ve yorum/işlem talimatlarını yeniden yazarken kaybediyor.
public enum MarkupFormatter {
    public enum Flavor: Sendable {
        case xml
        case html

        var label: String {
            switch self {
            case .xml: return "XML"
            case .html: return "HTML"
            }
        }
    }

    public struct FormatError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// HTML'de kapanışı olmayan elementler; derinliği artırmazlar.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    private enum Token {
        case open(raw: String, name: String)
        case close(raw: String, name: String)
        /// `<br/>`, `<?xml?>`, `<!-- -->`, `<!DOCTYPE>` — derinliği değiştirmez.
        case standalone(raw: String)
        case text(String)
    }

    public static func beautify(_ text: String, flavor: Flavor, indent: String = "  ") throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FormatError(message: "Geçersiz \(flavor.label): içerik boş")
        }
        let tokens = try tokenize(trimmed, flavor: flavor)
        return try render(tokens, flavor: flavor, indent: indent)
    }

    // MARK: - Tarama

    private static func tokenize(_ text: String, flavor: Flavor) throws -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var index = 0

        while index < chars.count {
            if chars[index] == "<" {
                let end = try findTagEnd(chars, from: index, flavor: flavor)
                let raw = String(chars[index...end])
                tokens.append(classify(raw))
                index = end + 1
            } else {
                var next = index
                while next < chars.count, chars[next] != "<" { next += 1 }
                let content = String(chars[index..<next])
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tokens.append(.text(content.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                index = next
            }
        }
        return tokens
    }

    /// Etiketin kapanış `>` konumunu bulur; tırnak içindeki `>` yok sayılır.
    private static func findTagEnd(_ chars: [Character], from start: Int, flavor: Flavor) throws -> Int {
        func find(_ terminator: [Character], from: Int) throws -> Int {
            var i = from
            while i + terminator.count <= chars.count {
                if Array(chars[i..<(i + terminator.count)]) == terminator {
                    return i + terminator.count - 1
                }
                i += 1
            }
            throw FormatError(
                message: "Geçersiz \(flavor.label): \"\(String(terminator))\" kapanışı bulunamadı."
            )
        }

        let rest = chars.count - start
        if rest >= 4, String(chars[start..<(start + 4)]) == "<!--" {
            return try find(Array("-->"), from: start + 4)
        }
        if rest >= 9, String(chars[start..<(start + 9)]) == "<![CDATA[" {
            return try find(Array("]]>"), from: start + 9)
        }
        if rest >= 2, chars[start + 1] == "?" {
            return try find(Array("?>"), from: start + 2)
        }

        var i = start + 1
        var quote: Character?
        while i < chars.count {
            let ch = chars[i]
            if let active = quote {
                if ch == active { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return i
            }
            i += 1
        }
        throw FormatError(message: "Geçersiz \(flavor.label): \"<\" etiketi \">\" ile kapatılmamış.")
    }

    private static func classify(_ raw: String) -> Token {
        if raw.hasPrefix("<!") || raw.hasPrefix("<?") {
            return .standalone(raw: raw)
        }
        if raw.hasSuffix("/>") {
            return .standalone(raw: raw)
        }
        if raw.hasPrefix("</") {
            return .close(raw: raw, name: tagName(raw, skip: 2))
        }
        return .open(raw: raw, name: tagName(raw, skip: 1))
    }

    private static func tagName(_ raw: String, skip: Int) -> String {
        var name = ""
        for ch in raw.dropFirst(skip) {
            if ch.isLetter || ch.isNumber || ch == ":" || ch == "-" || ch == "_" || ch == "." {
                name.append(ch)
            } else {
                break
            }
        }
        return name
    }

    // MARK: - Yazım

    private static func render(_ tokens: [Token], flavor: Flavor, indent: String) throws -> String {
        var lines: [String] = []
        var stack: [String] = []
        var index = 0

        func emit(_ text: String) {
            lines.append(String(repeating: indent, count: stack.count) + text)
        }

        while index < tokens.count {
            switch tokens[index] {
            case .standalone(let raw):
                emit(raw)
                index += 1

            case .text(let content):
                emit(content)
                index += 1

            case .open(let raw, let name):
                // HTML'de void elementler kapanmaz: derinliği artırma.
                if flavor == .html, voidElements.contains(name.lowercased()) {
                    emit(raw)
                    index += 1
                    continue
                }
                // <etiket>kısa metin</etiket> → tek satırda tut.
                if index + 2 < tokens.count,
                   case .text(let content) = tokens[index + 1],
                   case .close(_, let closeName) = tokens[index + 2],
                   closeName == name,
                   !content.contains("\n") {
                    emit("\(raw)\(content)</\(name)>")
                    index += 3
                    continue
                }
                // <etiket></etiket> → tek satır.
                if index + 1 < tokens.count,
                   case .close(_, let closeName) = tokens[index + 1],
                   closeName == name {
                    emit("\(raw)</\(name)>")
                    index += 2
                    continue
                }
                emit(raw)
                stack.append(name)
                index += 1

            case .close(let raw, let name):
                guard let top = stack.last else {
                    if flavor == .html {
                        // Başıboş kapanış: HTML'de yok say.
                        index += 1
                        continue
                    }
                    throw FormatError(
                        message: "Geçersiz XML: </\(name)> kapanışının açılışı yok."
                    )
                }
                if top == name {
                    stack.removeLast()
                    emit(raw)
                } else if flavor == .html, let depth = stack.lastIndex(of: name) {
                    // <li> gibi örtük kapanışlar: hedef etikete kadar yığını boşalt.
                    stack.removeSubrange(depth..<stack.count)
                    emit(raw)
                } else if flavor == .html {
                    index += 1
                    continue
                } else {
                    throw FormatError(
                        message: "Geçersiz XML: </\(name)> kapanışı beklenmiyordu, açık etiket <\(top)>."
                    )
                }
                index += 1
            }
        }

        if let unclosed = stack.last, flavor == .xml {
            throw FormatError(message: "Geçersiz XML: <\(unclosed)> etiketi kapatılmamış.")
        }
        return lines.joined(separator: "\n")
    }
}
