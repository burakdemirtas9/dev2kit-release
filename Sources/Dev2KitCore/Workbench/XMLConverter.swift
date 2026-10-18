import Foundation

/// JSON ↔ XML (docs/V2.md "1e"). Kural, Jackson `XmlMapper` / xml2js'e yakın
/// ve iki yönde aynı:
/// - Öznitelik `@ad`, eleman metni `#text`.
/// - Aynı adlı kardeş elemanlar dizi; dizi tekrar eden eleman.
/// - Kök: XML → JSON'da `{ "kökAdı": … }`; JSON → XML'de kök adı seçilir.
///
/// XML → JSON:
/// - Dış varlıklar ÇÖZÜLMEZ (XXE), `MarkupTools.validateXML` ile aynı.
/// - Metin kırpılır (girintili XML'in boşlukları veri sayılmaz); karışık
///   içerikte parçalar boşlukla birleşir. Yorum ve işleme talimatı düşer.
/// - Öznitelik sırası korunamaz (`XMLParser` sözlük veriyor): alfabetik.
/// - "Detect types" varsayılan KAPALI: XML'de her şey metin, yanlış tahmin
///   veriyi bozar.
///
/// JSON → XML:
/// - XML adı olamayan anahtar (`first name`, `1st`) güvenli ada çevrilir
///   (`first_name`, `_1st`) ve çıktının başında yorumla bildirilir.
/// - XML 1.0'da yazılamayan karakter (U+0000–U+001F, sekme/satır sonu hariç)
///   hata: sessizce atmak veriyi bozar.
public enum XMLConverter {
    static let maxDepth = JSONDocument.maxDepth

    // MARK: XML → JSON

    public static func toJSON(_ input: String, detectTypes: Bool, indent: String) throws -> String {
        let parser = XMLParser(data: Data(input.utf8))
        parser.shouldResolveExternalEntities = false
        let builder = TreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            if builder.tooDeep {
                throw WorkbenchIssue(message: "XML \(maxDepth) seviyeden derin")
            }
            if case .invalid(let issue) = MarkupTools.validateXML(input) { throw issue }
            throw WorkbenchIssue(message: "Geçersiz XML")
        }
        let document = JSONValue.object([(root.name, value(of: root, detectTypes: detectTypes))])
        return try JSONFormatter.beautify(document.compact(), indent: indent)
    }

    private final class Node {
        let name: String
        let attributes: [(key: String, value: String)]
        var children: [Node] = []
        var texts: [String] = []
        var pending = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }

        func flush() {
            let text = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
            pending = ""
        }
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var stack: [Node] = []
        var root: Node?
        var tooDeep = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard stack.count < XMLConverter.maxDepth else {
                tooDeep = true
                parser.abortParsing()
                return
            }
            stack.last?.flush()
            stack.append(Node(name: elementName, attributes: attributeDict))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let node = stack.popLast() else { return }
            node.flush()
            if let parent = stack.last { parent.children.append(node) } else { root = node }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.pending += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.pending += String(decoding: CDATABlock, as: UTF8.self)
        }
    }

    private static func value(of node: Node, detectTypes: Bool) -> JSONValue {
        func scalar(_ text: String) -> JSONValue {
            detectTypes ? ValueInference.value(of: text, emptyIsNull: false) : .string(text)
        }
        let text = node.texts.joined(separator: " ")
        if node.attributes.isEmpty, node.children.isEmpty { return scalar(text) }

        var members: [(key: String, value: JSONValue)] = node.attributes.map { ("@" + $0.key, scalar($0.value)) }
        var order: [String] = []
        var groups: [String: [JSONValue]] = [:]
        for child in node.children {
            if groups[child.name] == nil { order.append(child.name) }
            groups[child.name, default: []].append(value(of: child, detectTypes: detectTypes))
        }
        for name in order {
            let values = groups[name] ?? []
            members.append((name, values.count == 1 ? values[0] : .array(values)))
        }
        if !text.isEmpty { members.append(("#text", scalar(text))) }
        return .object(members)
    }

    // MARK: JSON → XML

    public static let defaultRootName = "root"
    static let arrayItemName = "item"

    public static func fromJSON(_ input: String, rootName: String, indent: String) throws -> String {
        let value = try JSONDocument.parse(input)
        var writer = Writer(indent: indent)
        let trimmed = rootName.trimmingCharacters(in: .whitespaces)
        let root = writer.name(trimmed.isEmpty ? defaultRootName : trimmed)
        try writer.element(root, value, depth: 0)

        var lines = [#"<?xml version="1.0" encoding="UTF-8"?>"#]
        if !writer.renamed.isEmpty {
            let shown = writer.renamed.prefix(10).map { "\"\($0.from)\" → \($0.to)" }.joined(separator: ", ")
            let more = writer.renamed.count > 10 ? " (+\(writer.renamed.count - 10))" : ""
            lines.append("<!-- Renamed (not valid XML names): \(commentSafe(shown + more)) -->")
        }
        return (lines + writer.lines).joined(separator: "\n")
    }

    private struct Writer {
        let indent: String
        var lines: [String] = []
        var renamed: [(from: String, to: String)] = []
        private var renamedKeys = Set<String>()

        init(indent: String) { self.indent = indent }

        mutating func name(_ key: String) -> String {
            let safe = XMLConverter.xmlName(key)
            if safe != key, renamedKeys.insert(key).inserted { renamed.append((key, safe)) }
            return safe
        }

        mutating func element(_ name: String, _ value: JSONValue, depth: Int) throws {
            let pad = String(repeating: indent, count: depth)
            switch value {
            case .object(let members):
                var attributes = ""
                var text: String?
                var children: [(key: String, value: JSONValue)] = []
                for member in members {
                    if member.key.hasPrefix("@"), member.key.count > 1, let scalar = try XMLConverter.scalarText(member.value) {
                        attributes += " \(self.name(String(member.key.dropFirst())))=\"\(XMLConverter.escape(scalar, attribute: true))\""
                    } else if member.key == "#text", let scalar = try XMLConverter.scalarText(member.value) {
                        text = scalar
                    } else {
                        children.append(member)
                    }
                }
                let open = "<\(name)\(attributes)"
                if children.isEmpty {
                    lines.append(pad + (text.map { "\(open)>\(XMLConverter.escape($0, attribute: false))</\(name)>" } ?? "\(open)/>"))
                    return
                }
                lines.append(pad + open + ">")
                if let text { lines.append(pad + indent + XMLConverter.escape(text, attribute: false)) }
                for child in children { try member(child.key, child.value, depth: depth + 1) }
                lines.append(pad + "</\(name)>")
            case .array(let items):
                guard !items.isEmpty else { lines.append(pad + "<\(name)/>"); return }
                lines.append(pad + "<\(name)>")
                for item in items { try element(XMLConverter.arrayItemName, item, depth: depth + 1) }
                lines.append(pad + "</\(name)>")
            default:
                if let scalar = try XMLConverter.scalarText(value) {
                    lines.append(pad + "<\(name)>\(XMLConverter.escape(scalar, attribute: false))</\(name)>")
                } else {
                    lines.append(pad + "<\(name)/>")
                }
            }
        }

        /// Nesne üyesi: dizi değer, aynı adla tekrar eden eleman olur.
        private mutating func member(_ key: String, _ value: JSONValue, depth: Int) throws {
            let elementName = name(key)
            if case .array(let items) = value, !items.isEmpty {
                for item in items { try element(elementName, item, depth: depth) }
            } else {
                try element(elementName, value, depth: depth)
            }
        }
    }

    /// Skaler değerin XML metni; `null` → `nil` (boş eleman), kapsayıcı → `nil`
    /// değil, çağıran eleman olarak yazar.
    private static func scalarText(_ value: JSONValue) throws -> String? {
        let text: String
        switch value {
        case .string(let string): text = string
        case .number(let raw): return raw
        case .bool(let flag): return flag ? "true" : "false"
        case .null, .object, .array: return nil
        }
        if let bad = text.unicodeScalars.first(where: { !isXMLChar($0) }) {
            throw WorkbenchIssue(message: "XML 1.0'da yazılamayan karakter: U+\(String(format: "%04X", bad.value))")
        }
        return text
    }

    private static func isXMLChar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD: return true
        case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
        default: return false
        }
    }

    static func escape(_ text: String, attribute: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            // Öznitelikte satır sonu/sekme okurken boşluğa normalleşir; korunsun.
            case "\n" where attribute: out += "&#10;"
            case "\r": out += "&#13;"
            case "\t" where attribute: out += "&#9;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Geçerli XML adı: harf ya da `_` ile başlar; harf, rakam, `-`, `.`, `:`,
    /// `_` içerir. Geçersiz karakter `_`; rakam/`-`/`.` ile başlıyorsa önüne `_`.
    static func xmlName(_ key: String) -> String {
        func isStart(_ scalar: Unicode.Scalar) -> Bool { scalar == "_" || scalar.properties.isAlphabetic }
        func isName(_ scalar: Unicode.Scalar) -> Bool {
            isStart(scalar) || scalar.properties.numericType != nil || scalar == "-" || scalar == "." || scalar == ":"
        }
        guard let first = key.unicodeScalars.first else { return "_" }
        var out = String.UnicodeScalarView()
        if !isStart(first) { out.append("_") }
        for (index, scalar) in key.unicodeScalars.enumerated() {
            if index == 0, !isStart(scalar), !isName(scalar) { continue }
            out.append(isName(scalar) ? scalar : "_")
        }
        return String(out)
    }

    /// XML yorumunda `--` olamaz.
    private static func commentSafe(_ text: String) -> String {
        var result = text
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "- -") }
        return result
    }
}
