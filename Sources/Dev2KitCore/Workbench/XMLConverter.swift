import Foundation

/// JSON → XML (docs/V2.md "1e"; XML → JSON 2026-10-20'de kullanıcı kararıyla
/// kaldırıldı). Kural Jackson `XmlMapper` / xml2js'e yakın:
/// - `@ad` anahtarı öznitelik, `#text` eleman metni.
/// - Dizi tekrar eden eleman; kök adı seçilir.
/// - XML adı olamayan anahtar (`first name`, `1st`) güvenli ada çevrilir
///   (`first_name`, `_1st`) ve çıktının başında yorumla bildirilir.
/// - XML 1.0'da yazılamayan karakter (U+0000–U+001F, sekme/satır sonu hariç)
///   hata: sessizce atmak veriyi bozar.
public enum XMLConverter {
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
            throw WorkbenchIssue(message: L10n.t("xml.badChar", "U+" + String(format: "%04X", bad.value)))
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
