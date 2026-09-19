import Foundation

/// Spring Boot yapılandırması: `application[-profil].yml|yaml|properties`.
///
/// YAML'ın tamamı değil, Spring ayar dosyalarında kullanılan alt kümesi
/// okunur (iç içe anahtarlar, listeler, yorumlar, tırnaklar, `---` ile ayrılmış
/// belgeler). Bağımlılık eklenmemesi için bilinçli bir sınırlama; tanınmayan
/// satırlar atlanır, dosya reddedilmez.
public struct SpringConfig: Sendable {
    /// profil → normalleştirilmiş anahtar → değer. Varsayılan profil "".
    private var values: [String: [String: String]] = [:]
    /// Kullanıcıya gösterilecek profil adları (varsayılan hariç).
    public private(set) var profiles: [String] = []

    public init() {}

    /// Dosya adından profil çıkarılır (`application-test.yml` → test).
    public mutating func load(fileName: String, text: String) {
        let lower = fileName.lowercased()
        let base = (lower as NSString).deletingPathExtension
        guard base == "application" || base.hasPrefix("application-") || base == "bootstrap" || base.hasPrefix("bootstrap-") else { return }
        let fileProfile = base.contains("-") ? String(base.split(separator: "-", maxSplits: 1)[1]) : ""
        let isYAML = lower.hasSuffix(".yml") || lower.hasSuffix(".yaml")
        let documents = isYAML ? Self.parseYAMLDocuments(text) : [Self.parseProperties(text)]
        for document in documents {
            // Çoklu belge: spring.config.activate.on-profile ya da eski spring.profiles
            let docProfile = document[Self.normalize("spring.config.activate.on-profile")]
                ?? document[Self.normalize("spring.profiles")]
            let profile = (docProfile?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }) ?? fileProfile
            add(document, profile: profile)
        }
    }

    private mutating func add(_ document: [String: String], profile: String) {
        values[profile, default: [:]].merge(document) { _, new in new }
        if !profile.isEmpty, !profiles.contains(profile) {
            profiles.append(profile)
            profiles.sort()
        }
    }

    /// Profil değeri varsayılanı ezer; `${…}` yer tutucuları çözülür.
    /// Çözülemeyen yer tutucu olduğu gibi kalır.
    public func value(for key: String, profile: String?) -> String? {
        rawValue(Self.normalize(key), profile: profile).map { resolve($0, profile: profile, depth: 0) }
    }

    private func rawValue(_ normalizedKey: String, profile: String?) -> String? {
        if let profile, !profile.isEmpty, let value = values[profile]?[normalizedKey] { return value }
        return values[""]?[normalizedKey]
    }

    /// `${a.b:varsayılan}` çözümü (iç içe, derinlik sınırlı).
    public func resolve(_ text: String, profile: String?, depth: Int = 0) -> String {
        guard depth < 8, text.contains("${") else { return text }
        var output = ""
        var rest = Substring(text)
        while let start = rest.range(of: "${") {
            output += rest[..<start.lowerBound]
            guard let end = Self.closingBrace(in: rest, from: start.upperBound) else {
                output += rest[start.lowerBound...]
                return output
            }
            let inner = String(rest[start.upperBound..<end])
            let (key, fallback) = Self.splitPlaceholder(inner)
            if let found = rawValue(Self.normalize(key), profile: profile) {
                output += resolve(found, profile: profile, depth: depth + 1)
            } else if let fallback {
                output += resolve(fallback, profile: profile, depth: depth + 1)
            } else {
                output += "${\(inner)}"
            }
            rest = rest[rest.index(after: end)...]
        }
        return output + rest
    }

    /// `a.b:c` → ("a.b", "c"); iç içe `${}` içindeki `:` bölünmez.
    static func splitPlaceholder(_ inner: String) -> (String, String?) {
        var depth = 0
        var index = inner.startIndex
        while index < inner.endIndex {
            let character = inner[index]
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == ":", depth == 0 {
                return (String(inner[..<index]), String(inner[inner.index(after: index)...]))
            }
            index = inner.index(after: index)
        }
        return (inner, nil)
    }

    private static func closingBrace(in text: Substring, from start: Substring.Index) -> Substring.Index? {
        var depth = 1
        var index = start
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Spring'in esnek eşleşmesi: `partner.base-url`, `partner.baseUrl`,
    /// `PARTNER_BASE_URL` aynı anahtardır.
    public static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0 != "-" && $0 != "_" }.replacingOccurrences(of: "[", with: ".").replacingOccurrences(of: "]", with: "")
    }

    // MARK: - .properties

    static func parseProperties(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            result[normalize(key)] = value
        }
        return result
    }

    // MARK: - YAML (Spring alt kümesi)

    static func parseYAMLDocuments(_ text: String) -> [[String: String]] {
        var documents: [[String: String]] = []
        var current: [String: String] = [:]
        // (girinti, anahtar yolu)
        var stack: [(indent: Int, path: String)] = []
        var listCounters: [String: Int] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces) == "---" {
                documents.append(current)
                current = [:]
                stack = []
                listCounters = [:]
                continue
            }
            let withoutComment = stripYAMLComment(rawLine)
            guard !withoutComment.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = withoutComment.prefix { $0 == " " }.count
            var content = withoutComment.trimmingCharacters(in: .whitespaces)

            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            let parent = stack.last?.path ?? ""

            if content.hasPrefix("- ") || content == "-" {
                // Liste elemanı: parent[0], parent[1]…
                let index = listCounters[parent, default: 0]
                listCounters[parent] = index + 1
                content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
                let itemPath = "\(parent).\(index)"
                if let (key, value) = splitYAMLPair(content) {
                    // "- name: x" : liste elemanı bir harita
                    stack.append((indent, itemPath))
                    let path = "\(itemPath).\(key)"
                    if let value { current[normalize(path)] = value } else { stack.append((indent + 2, path)) }
                } else {
                    current[normalize(itemPath)] = unquote(content)
                }
                continue
            }
            guard let (key, value) = splitYAMLPair(content) else { continue }
            let path = parent.isEmpty ? key : "\(parent).\(key)"
            if let value {
                current[normalize(path)] = value
            } else {
                stack.append((indent, path))
            }
        }
        documents.append(current)
        return documents.filter { !$0.isEmpty }
    }

    /// `anahtar: değer` → (anahtar, değer); değer yoksa (alt harita) nil.
    private static func splitYAMLPair(_ content: String) -> (String, String?)? {
        var quote: Character?
        var index = content.startIndex
        while index < content.endIndex {
            let character = content[index]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ":" {
                let next = content.index(after: index)
                if next == content.endIndex || content[next] == " " {
                    let key = unquote(String(content[..<index]).trimmingCharacters(in: .whitespaces))
                    let value = String(content[next...]).trimmingCharacters(in: .whitespaces)
                    // `|` ve `>` çok satırlı metin: değer okunmaz, anahtar alt harita sayılmaz.
                    if value == "|" || value == ">" || value == "|-" || value == ">-" { return (key, "") }
                    return (key, value.isEmpty ? nil : unquote(value))
                }
            }
            index = content.index(after: index)
        }
        return nil
    }

    private static func stripYAMLComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for (offset, character) in line.enumerated() {
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous == " " || offset == 0 {
                return String(line.prefix(offset))
            }
            previous = character
        }
        return line
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else { return text }
        return String(text.dropFirst().dropLast())
    }
}
