import Foundation

/// Spring yapılandırması: YAML ↔ `.properties` (kullanıcı isteği, 2026-10-20).
///
/// YAML → Properties, Spring'in YAML'ı düzleştirme kuralıyla aynı
/// (`YamlProcessor`): anahtarlar `.` ile birleşir, `[`… ile başlayan anahtar
/// noktasız eklenir, dizi öğesi `[i]`, null ve boş kapsayıcı boş değer.
/// `---` belgeleri Spring'in properties ayracı `#---` olur.
///
/// Properties → YAML, `java.util.Properties` okuma kuralıyla: `#`/`!` yorum,
/// `=` `:` ya da boşluk ayıraç, satır sonu `\` devam, `\uXXXX` kaçışları;
/// `a.b[0]` dizi, `[x.y]` noktalı anahtar. Değer tipi tutucu: yalnızca düz
/// sayı ve `true`/`false` tırnaksız yazılır; `no`, `on`, `012` gibi YAML'ın
/// başka tip okuyacağı metinler tırnaklanır (`YAMLWriter`).
///
/// Properties ÇIKTISINDA ASCII dışı karakterler `\uXXXX` yazılır: Spring Boot
/// `.properties` dosyasını ISO-8859-1 okur; UTF-8 kaydedilmiş "ş" bozulur.
public enum PropertiesConverter {
    /// `a[100000]` gibi tek satırın milyonluk dizi kurdurmaması için.
    public static let maxListIndex = 10_000

    // MARK: - YAML → Properties

    public static func fromYAML(_ input: String) throws -> String {
        let documents = try YAMLReader.documents(input)
        var blocks: [String] = []
        for document in documents {
            var lines: [String] = []
            switch document {
            case .object, .array: flatten(document, path: "", into: &lines)
            case .null: break
            default: throw WorkbenchIssue(message: "Belgenin kökü bir eşleme (`anahtar: değer`) olmalı.")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n#---\n")
    }

    static func flatten(_ value: JSONValue, path: String, into lines: inout [String]) {
        switch value {
        case .object(let members):
            if members.isEmpty, !path.isEmpty { lines.append(escapeKey(path) + "="); return }
            for member in members {
                let child: String
                if path.isEmpty { child = member.key }
                else if member.key.hasPrefix("[") { child = path + member.key }
                else { child = path + "." + member.key }
                flatten(member.value, path: child, into: &lines)
            }
        case .array(let items):
            if items.isEmpty { lines.append(escapeKey(path) + "="); return }
            for (index, item) in items.enumerated() {
                flatten(item, path: "\(path)[\(index)]", into: &lines)
            }
        case .string(let text): lines.append(escapeKey(path) + "=" + escapeValue(text))
        case .number(let raw): lines.append(escapeKey(path) + "=" + raw)
        case .bool(let flag): lines.append(escapeKey(path) + "=" + (flag ? "true" : "false"))
        case .null: lines.append(escapeKey(path) + "=")
        }
    }

    static func escapeKey(_ key: String) -> String {
        var out = ""
        for (index, scalar) in key.unicodeScalars.enumerated() {
            switch scalar {
            case " ": out += "\\ "
            case "=", ":": out += "\\" + String(scalar)
            case "#", "!": out += index == 0 ? "\\" + String(scalar) : String(scalar)
            default: out += escapeCommon(scalar)
            }
        }
        return out
    }

    static func escapeValue(_ value: String) -> String {
        var out = ""
        for (index, scalar) in value.unicodeScalars.enumerated() {
            // Baştaki boşluk okuyucuda yutulur; korunsun diye kaçışlı.
            if index == 0, scalar == " " { out += "\\ "; continue }
            out += escapeCommon(scalar)
        }
        return out
    }

    private static func escapeCommon(_ scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "\\": return "\\\\"
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        case "\u{0C}": return "\\f"
        default:
            if scalar.value < 0x20 || scalar.value > 0x7E {
                // UTF-16 birimleri: BMP dışı karakter vekil çift olarak yazılır.
                return String(scalar).utf16.map { String(format: "\\u%04X", $0) }.joined()
            }
            return String(scalar)
        }
    }

    // MARK: - Properties → YAML

    public static func toYAML(_ input: String) throws -> String {
        try documents(input).map { YAMLWriter.write($0.jsonValue) }.joined(separator: "\n---\n")
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

    struct Entry: Equatable {
        let key: String
        let value: String
        let line: Int
    }

    /// Mantıksal satırlar → anahtar/değer; `#---` / `!---` belge ayracı.
    static func entries(_ input: String) throws -> [[Entry]] {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let physical = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var documents: [[Entry]] = [[]]
        var index = 0
        while index < physical.count {
            let startLine = index + 1
            var line = String(physical[index].drop { $0 == " " || $0 == "\t" || $0 == "\u{0C}" })
            index += 1
            if line == "#---" || line == "!---" { documents.append([]); continue }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") { continue }
            // Sonda tek sayıda `\`: alt satırla devam.
            while endsWithContinuation(line), index < physical.count {
                line.removeLast()
                line += physical[index].drop { $0 == " " || $0 == "\t" || $0 == "\u{0C}" }
                index += 1
            }
            if endsWithContinuation(line) { line.removeLast() }
            let (rawKey, rawValue) = splitEntry(line)
            documents[documents.count - 1].append(
                Entry(key: try unescape(rawKey, line: startLine), value: try unescape(rawValue, line: startLine), line: startLine)
            )
        }
        return documents.filter { !$0.isEmpty }
    }

    static func endsWithContinuation(_ line: String) -> Bool {
        var count = 0
        for character in line.reversed() { if character == "\\" { count += 1 } else { break } }
        return count % 2 == 1
    }

    /// Anahtar: kaçışsız ilk `=`, `:` ya da boşluğa kadar.
    static func splitEntry(_ line: String) -> (String, String) {
        let characters = Array(line)
        var index = 0
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "=" || character == ":" || character == " " || character == "\t" || character == "\u{0C}" { break }
            index += 1
        }
        let key = String(characters[..<index])
        var valueStart = index
        while valueStart < characters.count, characters[valueStart] == " " || characters[valueStart] == "\t" || characters[valueStart] == "\u{0C}" { valueStart += 1 }
        if valueStart < characters.count, characters[valueStart] == "=" || characters[valueStart] == ":" {
            valueStart += 1
            while valueStart < characters.count, characters[valueStart] == " " || characters[valueStart] == "\t" || characters[valueStart] == "\u{0C}" { valueStart += 1 }
        }
        return (key, String(characters[valueStart...]))
    }

    static func unescape(_ text: String, line: Int) throws -> String {
        var out = ""
        var iterator = Array(text).makeIterator()
        var pendingHigh: UInt16?
        while let character = iterator.next() {
            guard character == "\\" else { out.append(character); continue }
            guard let escape = iterator.next() else { break }
            switch escape {
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "f": out.append("\u{0C}")
            case "u":
                var hex = ""
                for _ in 0..<4 { if let next = iterator.next() { hex.append(next) } }
                guard hex.count == 4, let unit = UInt16(hex, radix: 16) else {
                    throw WorkbenchIssue(message: "Geçersiz \\u kaçışı: \\u\(hex)", line: line)
                }
                if (0xD800...0xDBFF).contains(unit) { pendingHigh = unit; continue }
                if (0xDC00...0xDFFF).contains(unit), let high = pendingHigh {
                    out += String(decoding: [high, unit], as: UTF16.self)
                    pendingHigh = nil
                    continue
                }
                out += String(decoding: [unit], as: UTF16.self)
            default:
                out.append(escape)
            }
            pendingHigh = nil
        }
        return out
    }

    // MARK: - Ağaç

    /// Properties anahtarlarından kurulan sıralı ağaç.
    final class Node {
        enum Kind { case unset, leaf(String), map, list }
        var kind: Kind = .unset
        var keys: [String] = []
        var children: [String: Node] = [:]
        var items: [Int: Node] = [:]
        /// İlk tanımlandığı satır (çakışma mesajında).
        var line = 0

        var jsonValue: JSONValue {
            switch kind {
            case .unset: return .null
            case .leaf(let text):
                if text == "true" || text == "false" { return .bool(text == "true") }
                if ValueInference.isPlainNumber(text) { return .number(text) }
                return .string(text)
            case .map: return .object(keys.map { ($0, children[$0]!.jsonValue) })
            case .list:
                let count = (items.keys.max() ?? -1) + 1
                return .array((0..<count).map { items[$0]?.jsonValue ?? .null })
            }
        }
    }

    enum Segment: Equatable {
        case key(String)
        case index(Int)
    }

    /// `a.b[0].c`, `map.[x.y]`, `a[0][1]`.
    static func segments(of key: String, line: Int) throws -> [Segment] {
        var result: [Segment] = []
        var current = ""
        var characters = Array(key)[...]
        func flush() { if !current.isEmpty { result.append(.key(current)); current = "" } }
        while let character = characters.first {
            characters = characters.dropFirst()
            switch character {
            case ".":
                flush()
            case "[":
                flush()
                guard let close = characters.firstIndex(of: "]") else {
                    throw WorkbenchIssue(message: "`[` kapanmamış: \(key)", line: line)
                }
                let inner = String(characters[..<close])
                characters = characters[characters.index(after: close)...]
                if let number = Int(inner), number >= 0, inner.allSatisfy(\.isNumber) {
                    guard number <= maxListIndex else {
                        throw WorkbenchIssue(message: "Dizi sırası \(maxListIndex)'den büyük: \(key)", line: line)
                    }
                    result.append(.index(number))
                } else {
                    result.append(.key(inner))
                }
            default:
                current.append(character)
            }
        }
        flush()
        guard !result.isEmpty else { throw WorkbenchIssue(message: "Boş anahtar.", line: line) }
        return result
    }

    static func documents(_ input: String) throws -> [Node] {
        try entries(input).map { entries in
            let root = Node()
            root.kind = .map
            for entry in entries {
                let path = try segments(of: entry.key, line: entry.line)
                var node = root
                for (position, segment) in path.enumerated() {
                    let isLast = position == path.count - 1
                    let next: Node
                    switch segment {
                    case .key(let name):
                        try ensure(node, is: .map, entry: entry, path: path, upTo: position)
                        if let existing = node.children[name] { next = existing } else {
                            next = Node(); next.line = entry.line
                            node.children[name] = next; node.keys.append(name)
                        }
                    case .index(let number):
                        try ensure(node, is: .list, entry: entry, path: path, upTo: position)
                        if let existing = node.items[number] { next = existing } else {
                            next = Node(); next.line = entry.line
                            node.items[number] = next
                        }
                    }
                    if isLast {
                        switch next.kind {
                        case .unset, .leaf: next.kind = .leaf(entry.value)   // tekrar eden anahtarda son değer geçerli
                        case .map, .list:
                            throw WorkbenchIssue(
                                message: "`\(entry.key)` hem değer hem alt anahtarları olan bir grup olarak kullanılmış (satır \(next.line)); YAML'da ikisi birden olamaz.",
                                line: entry.line)
                        }
                    }
                    node = next
                }
            }
            return root
        }
    }

    private enum Container { case map, list }

    private static func ensure(_ node: Node, is container: Container, entry: Entry, path: [Segment], upTo position: Int) throws {
        switch (node.kind, container) {
        case (.unset, .map): node.kind = .map
        case (.unset, .list): node.kind = .list
        case (.map, .map), (.list, .list): break
        case (.leaf, _):
            throw WorkbenchIssue(
                message: "`\(entry.key)`: üst anahtar satır \(node.line)'de bir değer olarak tanımlı; YAML'da hem değer hem grup olamaz.",
                line: entry.line)
        default:
            throw WorkbenchIssue(
                message: "`\(entry.key)`: aynı anahtar hem dizi (`[0]`) hem eşleme olarak kullanılmış.",
                line: entry.line)
        }
    }
}
