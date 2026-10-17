import Foundation

// MARK: - Proje dizini

/// Dosyalar arası bilgiler: sabitler, `@Value` alanları, DTO'lar, istemci bean'leri.
struct ProjectIndex {
    /// "Sınıf.SABIT" → ifade
    var qualifiedConstants: [String: String] = [:]
    /// dosya → SABIT → ifade
    var fileConstants: [String: [String: String]] = [:]
    /// dosya → alan/parametre adı → ayar anahtarı
    var valueFields: [String: [String: String]] = [:]
    var classes: [String: [(name: String, type: String)]] = [:]
    var superclasses: [String: String] = [:]
    var enums: [String: String] = [:]
    /// bean adı → (tür, temel adres ifadesi, dosya)
    var clientBeans: [String: (type: String, baseExpression: String, file: String)] = [:]
    /// Bean'in adres ifadesi kendi dosyasında (ör. `@Value` parametresiyle) çözülür.
    var sourcesByPath: [String: JavaSource] = [:]

    init(sources: [JavaSource]) {
        for source in sources {
            sourcesByPath[source.path] = source
            let typeName = source.primaryTypeName ?? ""
            for match in source.matches(#"\bstatic\s+final\s+String\s+([A-Za-z_]\w*)\s*=\s*([^;]+);"#) {
                fileConstants[source.path, default: [:]][match.groups[0]] = match.groups[1]
                if !typeName.isEmpty { qualifiedConstants["\(typeName).\(match.groups[0])"] = match.groups[1] }
            }
            for match in source.matches(#"@Value\s*\(\s*"\$\{([^"]+)\}"\s*\)\s*(?:(?:private|protected|public|final)\s+)*[\w.<>\[\]]+\s+([A-Za-z_]\w*)"#) {
                // Varsayılan değer korunur: anahtar ayarlarda yoksa Spring onu kullanır.
                valueFields[source.path, default: [:]][match.groups[1]] = match.groups[0]
            }
            indexTypes(in: source)
            indexClientBeans(in: source)
        }
    }

    private mutating func indexTypes(in source: JavaSource) {
        for match in source.matches(#"\benum\s+([A-Za-z_]\w*)[^{]*\{\s*([A-Z_][A-Z0-9_]*)"#) {
            enums[match.groups[0]] = match.groups[1]
        }
        for match in source.matches(#"\brecord\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\("#) {
            guard let paren = source.text.dropFirst(match.offset).firstIndex(of: "(") else { continue }
            let start = source.text.distance(from: source.text.startIndex, to: paren)
            guard let end = source.matching(from: start) else { continue }
            classes[match.groups[0]] = JavaSyntax.splitTopLevel(source.slice((start + 1)..<end)).compactMap(Self.field)
        }
        for match in source.matches(#"\bclass\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*(?:extends\s+([A-Za-z_][\w.]*))?[^{]*\{"#) {
            let name = match.groups[0]
            if !match.groups[1].isEmpty { superclasses[name] = match.groups[1].split(separator: ".").last.map(String.init) }
            guard let brace = source.text.dropFirst(match.offset).firstIndex(of: "{") else { continue }
            let start = source.text.distance(from: source.text.startIndex, to: brace)
            guard let end = source.matching(from: start) else { continue }
            classes[name] = Self.fields(in: source.slice((start + 1)..<end))
        }
    }

    /// Sınıf gövdesinin yalnızca üst düzey, statik olmayan alanları.
    private static func fields(in body: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var depth = 0
        var statement = ""
        for character in body {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1; if depth == 0 { statement = "" }; continue }
            guard depth == 0 else { continue }
            if character == ";" {
                // Annotation argümanları ve ilk değer (`= new ArrayList<>()`) parantez
                // içerebilir; metot/kurucu ayrımı yalnızca bildirimin kendisine bakar.
                // Annotation argümanında da `=` olabilir (`@Column(name = "x")`):
                // bildirim, annotation'lar okunduktan SONRA ilk değerinden ayrılır.
                let (annotations, afterAnnotations) = Annotations.read(statement)
                let bare = afterAnnotations.components(separatedBy: "=").first ?? ""
                let words = bare.split(whereSeparator: { $0.isWhitespace })
                if !bare.contains("("), !words.contains("static"), let field = field(bare) {
                    let jsonName = annotations.first { $0.name == "JsonProperty" }?.args["value"].flatMap(JavaSyntax.stringLiteral)
                    result.append((jsonName ?? field.0, field.1))
                }
                statement = ""
            } else {
                statement.append(character)
            }
        }
        return result
    }

    /// `@JsonProperty("ad") private List<X> alan` → ("ad", "List<X>")
    static func field(_ declaration: String) -> (String, String)? {
        var text = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        var jsonName: String?
        while text.hasPrefix("@") {
            let nameEnd = text.dropFirst().firstIndex { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") } ?? text.endIndex
            let annotation = String(text[text.index(after: text.startIndex)..<nameEnd])
            var rest = text[nameEnd...].drop { $0 == " " }
            if rest.first == "(" {
                var depth = 0
                var closing: Substring.Index?
                for index in rest.indices {
                    if rest[index] == "(" { depth += 1 }
                    if rest[index] == ")" { depth -= 1; if depth == 0 { closing = index; break } }
                }
                // Kapanmamış annotation: bildirim okunamaz, alan atlanır.
                guard let end = closing else { return nil }
                let args = String(rest[rest.index(after: rest.startIndex)..<end])
                if annotation.hasSuffix("JsonProperty"), let value = JavaSyntax.annotationArguments(args)["value"].flatMap(JavaSyntax.stringLiteral) {
                    jsonName = value
                }
                rest = rest[rest.index(after: end)...]
            }
            text = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let words = text.replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: " ")
            .filter { !$0.isEmpty && !["private", "protected", "public", "final", "transient", "volatile"].contains($0) }
        guard words.count >= 2, let name = words.last, name.first?.isLetter == true || name.first == "_" else { return nil }
        let type = words.dropLast().joined(separator: " ")
        return (jsonName ?? name, type)
    }

    /// `@Bean WebClient partnerClient(...) { … .baseUrl(x) … }`
    private mutating func indexClientBeans(in source: JavaSource) {
        for match in source.matches(#"@Bean\b[^;{]*?\b(WebClient|RestClient|RestTemplate)\s+([A-Za-z_]\w*)\s*\("#) {
            // Gövde parametre listesinden sonra başlar; parametredeki
            // `@Value("${x}")` metnindeki süslü parantez gövde sanılmasın.
            guard let paren = source.text.dropFirst(match.offset).firstIndex(of: "(") else { continue }
            guard let paramsEnd = source.matching(from: source.text.distance(from: source.text.startIndex, to: paren)),
                  let brace = source.text.dropFirst(paramsEnd).firstIndex(of: "{") else { continue }
            let start = source.text.distance(from: source.text.startIndex, to: brace)
            guard let end = source.matching(from: start) else { continue }
            let body = source.slice(start..<end)
            if let base = Self.baseExpression(in: body) {
                clientBeans[match.groups[1]] = (match.groups[0], base, source.path)
            }
        }
    }

    /// `.baseUrl(x)`, `.rootUri(x)`, `WebClient.create(x)`, `RestClient.create(x)`
    static func baseExpression(in text: String) -> String? {
        for marker in [".baseUrl(", ".rootUri(", "WebClient.create(", "RestClient.create("] {
            guard let range = text.range(of: marker) else { continue }
            var depth = 1
            var index = range.upperBound
            while index < text.endIndex {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1; if depth == 0 { break } }
                index = text.index(after: index)
            }
            let argument = String(text[range.upperBound..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !argument.isEmpty { return argument }
        }
        return nil
    }

    // MARK: Örnek gövde

    func sample(forType rawType: String, depth: Int = 0) -> Any {
        let type = rawType.replacingOccurrences(of: " ", with: "")
        guard depth < 5 else { return [String: Any]() }
        if type.hasSuffix("[]") { return [sample(forType: String(type.dropLast(2)), depth: depth + 1)] }
        let base = type.split(separator: "<").first.map(String.init)?.split(separator: ".").last.map(String.init) ?? type
        let generic = type.firstIndex(of: "<").map { String(type[type.index(after: $0)..<type.index(before: type.endIndex)]) }
        switch base {
        case "String", "CharSequence": return "string"
        case "int", "Integer", "long", "Long", "short", "Short", "byte", "Byte", "BigInteger": return 0
        case "double", "Double", "float", "Float", "BigDecimal", "Number": return 0
        case "boolean", "Boolean": return false
        case "char", "Character": return "a"
        case "UUID": return "00000000-0000-0000-0000-000000000000"
        case "LocalDate": return "2026-01-01"
        case "LocalDateTime": return "2026-01-01T00:00:00"
        case "OffsetDateTime", "ZonedDateTime", "Instant", "Date": return "2026-01-01T00:00:00Z"
        case "LocalTime": return "00:00:00"
        case "List", "Set", "Collection", "Iterable", "ArrayList", "HashSet", "LinkedList":
            return [generic.map { sample(forType: $0, depth: depth + 1) } ?? "string"]
        case "Optional":
            return generic.map { sample(forType: $0, depth: depth + 1) } ?? NSNull()
        case "Map", "HashMap", "LinkedHashMap", "JsonNode", "Object", "ObjectNode":
            return [String: Any]()
        default:
            if let constant = enums[base] { return constant }
            guard classes[base] != nil else { return [String: Any]() }
            var object: [String: Any] = [:]
            var current: String? = base
            var visited = Set<String>()
            while let name = current, !visited.contains(name) {
                visited.insert(name)
                for field in classes[name] ?? [] where object[field.name] == nil {
                    object[field.name] = sample(forType: field.type, depth: depth + 1)
                }
                current = superclasses[name]
            }
            return object
        }
    }

    func sampleJSON(forType type: String) -> String? {
        let value = sample(forType: type)
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
