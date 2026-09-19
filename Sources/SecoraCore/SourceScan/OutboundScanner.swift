import Foundation

/// Bir servisin kaynak kodundan dışarıya giden HTTP çağrıları.
public struct OutboundCall: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable, CaseIterable {
        case feign = "Feign"
        case httpExchange = "HTTP Interface"
        case restTemplate = "RestTemplate"
        case webClient = "WebClient"
        case restClient = "RestClient"
    }

    /// Temel adresin nereden geldiği.
    public enum Origin: Hashable, Sendable {
        /// Ayar yer tutucusu: `partner.url` ya da varsayılanıyla `partner.url:http://x`.
        case property(String)
        /// Kodda yazılı adres.
        case literal(String)
        /// Bilinmiyor (servis keşfi, çalışma anında kurulan istemci).
        case unknown
    }

    public let source: Source
    public let client: String
    public let operation: String
    public let method: HTTPMethod
    /// Temel adres değişkeninin adı (`{{partner-customer}}`).
    public let baseVariable: String
    public let baseOrigin: Origin
    /// Değişkenden sonraki yol; çalışma anı değerleri `{{ad}}`.
    public let path: String
    public let query: [KeyValueEntry]
    public let headers: [KeyValueEntry]
    public let bodyType: String?
    public let bodySample: String?
    /// `dosya:satır`
    public let location: String
    /// Adresin tamamı koddan çözülebildi mi.
    public let isComplete: Bool

    public var id: String { "\(location)|\(operation)" }
}

public struct OutboundScanResult: Sendable {
    public let projectName: String
    public let calls: [OutboundCall]
    public let config: SpringConfig
    public let javaFileCount: Int
    public let notes: [String]
}

/// Kaynak koddan giden çağrıları bulur. Dosyalar yalnızca okunur; hiçbir şey
/// derlenmez, çalıştırılmaz, ağa çıkılmaz.
public enum OutboundScanner {
    public enum ScanError: Error, LocalizedError {
        case notADirectory
        case noJavaSources

        public var errorDescription: String? {
            switch self {
            case .notADirectory: return "Seçilen yol bir klasör değil."
            case .noJavaSources: return "Klasörde Java kaynak dosyası bulunamadı (src/test hariç)."
            }
        }
    }

    static let skippedDirectories: Set<String> = [".git", ".idea", ".gradle", ".mvn", "target", "build", "out", "node_modules", ".vscode", "bin"]
    static let maxFiles = 20_000
    static let maxFileBytes = 2 * 1024 * 1024
    static let maxTotalBytes = 150 * 1024 * 1024

    // MARK: - Klasör

    public static func scan(directory: URL) throws -> OutboundScanResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScanError.notADirectory
        }
        var files: [(path: String, text: String)] = []
        var kotlinCount = 0
        var totalBytes = 0
        var truncated = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
        let rootPath = directory.standardizedFileURL.path

        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if skippedDirectories.contains(name) { enumerator?.skipDescendants() }
                continue
            }
            // Sembolik bağlar izlenmez: seçilen klasörün dışına çıkılmasın.
            if values?.isSymbolicLink == true { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Testlerdeki sahte istemciler ve test ayarları gerçek çağrılar değildir.
            if relative.contains("src/test/") { continue }
            let lower = name.lowercased()
            if lower.hasSuffix(".kt") { kotlinCount += 1; continue }
            let isJava = lower.hasSuffix(".java")
            let isConfig = (lower.hasPrefix("application") || lower.hasPrefix("bootstrap"))
                && (lower.hasSuffix(".yml") || lower.hasSuffix(".yaml") || lower.hasSuffix(".properties"))
            guard isJava || isConfig else { continue }
            let size = values?.fileSize ?? 0
            guard size <= maxFileBytes else { continue }
            guard files.count < maxFiles, totalBytes + size <= maxTotalBytes else { truncated = true; break }
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            totalBytes += size
            files.append((relative, String(decoding: data, as: UTF8.self)))
        }

        var result = try scan(files: files, projectName: directory.lastPathComponent)
        var notes = result.notes
        if kotlinCount > 0 { notes.append("\(kotlinCount) Kotlin dosyası taranmadı (şimdilik yalnızca Java).") }
        if truncated { notes.append("Proje çok büyük; ilk \(files.count) dosya tarandı.") }
        result = OutboundScanResult(projectName: result.projectName, calls: result.calls, config: result.config, javaFileCount: result.javaFileCount, notes: notes)
        return result
    }

    // MARK: - Dosyalar

    public static func scan(files: [(path: String, text: String)], projectName: String) throws -> OutboundScanResult {
        var config = SpringConfig()
        var sources: [JavaSource] = []
        for file in files {
            if file.path.lowercased().hasSuffix(".java") {
                sources.append(JavaSource(path: file.path, text: file.text))
            } else {
                config.load(fileName: (file.path as NSString).lastPathComponent, text: file.text)
            }
        }
        guard !sources.isEmpty else { throw ScanError.noJavaSources }

        let index = ProjectIndex(sources: sources)
        var calls: [OutboundCall] = []
        for source in sources {
            calls += DeclarativeClients.find(in: source, index: index)
            calls += TemplateCalls.find(in: source, index: index)
        }
        calls.sort { ($0.client, $0.operation, $0.location) < ($1.client, $1.operation, $1.location) }
        return OutboundScanResult(projectName: projectName, calls: calls, config: config, javaFileCount: sources.count, notes: [])
    }
}

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

// MARK: - Adres ifadeleri

/// Adres ifadesinin parçaları.
enum URLSegment: Equatable {
    case literal(String)
    /// Ayar anahtarı (`${partner.url}` ya da `@Value` alanı).
    case property(String)
    /// Çalışma anında belli olan değer: `{{ad}}` olur.
    case runtime(String)
}

struct URLExpression {
    var segments: [URLSegment] = []
    var isComplete = true

    /// Java ifadesini parçalara ayırır: metin sabiti, sabit, `@Value` alanı,
    /// birleştirme (`+`), `String.format`; kalanı çalışma anı değeridir.
    static func evaluate(_ expression: String, source: JavaSource, index: ProjectIndex, depth: Int = 0) -> URLExpression {
        var result = URLExpression()
        guard depth < 6 else { result.segments = [.runtime("deger")]; result.isComplete = false; return result }
        for part in JavaSyntax.splitTopLevel(expression, separator: "+") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let literal = JavaSyntax.stringLiteral(trimmed) {
                result.segments += literalSegments(literal)
            } else if let constant = index.fileConstants[source.path]?[trimmed] ?? index.qualifiedConstants[trimmed] {
                let inner = evaluate(constant, source: source, index: index, depth: depth + 1)
                result.segments += inner.segments
                result.isComplete = result.isComplete && inner.isComplete
            } else if let key = index.valueFields[source.path]?[trimmed] {
                result.segments.append(.property(key))
            } else if trimmed.hasPrefix("String.format("), trimmed.hasSuffix(")"), let inner = innerArguments(trimmed) {
                let arguments = JavaSyntax.splitTopLevel(inner)
                if let format = arguments.first.flatMap(JavaSyntax.stringLiteral) {
                    var names = arguments.dropFirst().map(identifierName).makeIterator()
                    var text = ""
                    var iterator = format.makeIterator()
                    while let character = iterator.next() {
                        if character == "%", let spec = iterator.next() {
                            if spec == "%" { text.append("%"); continue }
                            text += "{\(names.next() ?? "deger")}"
                        } else {
                            text.append(character)
                        }
                    }
                    result.segments += literalSegments(text)
                    result.isComplete = false
                } else {
                    result.segments.append(.runtime("deger")); result.isComplete = false
                }
            } else if !trimmed.isEmpty {
                result.segments.append(.runtime(identifierName(trimmed)))
                result.isComplete = false
            }
        }
        return result
    }

    /// `"${a.b}/x/{id}"` → property(a.b), literal(/x/), runtime(id)
    static func literalSegments(_ text: String) -> [URLSegment] {
        var segments: [URLSegment] = []
        var buffer = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("${"), let end = text[index...].firstIndex(of: "}") {
                if !buffer.isEmpty { segments.append(.literal(buffer)); buffer = "" }
                segments.append(.property(String(text[text.index(index, offsetBy: 2)..<end])))
                index = text.index(after: end)
            } else if text[index] == "{", let end = text[index...].firstIndex(of: "}") {
                if !buffer.isEmpty { segments.append(.literal(buffer)); buffer = "" }
                let name = String(text[text.index(after: index)..<end]).split(separator: ":").first.map(String.init) ?? "deger"
                segments.append(.runtime(name))
                index = text.index(after: end)
            } else {
                buffer.append(text[index])
                index = text.index(after: index)
            }
        }
        if !buffer.isEmpty { segments.append(.literal(buffer)) }
        return segments
    }

    /// `request.getId()` → id, `buildUrl(x)` → buildUrl, `customerId` → customerId
    static func identifierName(_ expression: String) -> String {
        var cleaned = expression.trimmingCharacters(in: .whitespaces)
        // Metot çağrısında argüman değil metodun kendisi değeri adlandırır.
        if let paren = cleaned.firstIndex(of: "(") { cleaned = String(cleaned[..<paren]) }
        let last = cleaned.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).last.map(String.init) ?? "deger"
        if last.hasPrefix("get"), last.count > 3 {
            let rest = last.dropFirst(3)
            return rest.prefix(1).lowercased() + rest.dropFirst()
        }
        return last.isEmpty ? "deger" : last
    }
}

// MARK: - Feign ve HTTP Interface

enum DeclarativeClients {
    static func find(in source: JavaSource, index: ProjectIndex) -> [OutboundCall] {
        var calls: [OutboundCall] = []
        for match in source.matches(#"@(FeignClient|HttpExchange)\b"#) {
            let isFeign = match.groups[0] == "FeignClient"
            var cursor = match.offset + match.groups[0].count + 1
            var annotationArgs: [String: String] = [:]
            if let open = nextNonSpace(source, from: cursor), source.code[open] == "(", let close = source.matching(from: open) {
                annotationArgs = JavaSyntax.annotationArguments(source.slice((open + 1)..<close))
                cursor = close + 1
            }
            // Annotation bir arayüze ait olmalı (metot üzerindeki @HttpExchange değil).
            guard let interfaceMatch = source.matches(#"\binterface\s+([A-Za-z_]\w*)"#).first(where: { $0.offset >= cursor }),
                  source.slice(cursor..<interfaceMatch.offset).components(separatedBy: CharacterSet(charactersIn: ";(){}")).count <= 3 || isFeign,
                  let brace = source.text.dropFirst(interfaceMatch.offset).firstIndex(of: "{") else { continue }
            let open = source.text.distance(from: source.text.startIndex, to: brace)
            guard let close = source.matching(from: open) else { continue }

            let interfaceName = interfaceMatch.groups[0]
            let nameExpression = annotationArgs["name"] ?? annotationArgs["value"] ?? annotationArgs["contextId"]
            let clientName = nameExpression.flatMap(JavaSyntax.stringLiteral)
                .map { SpringConfig().resolve($0, profile: nil) }
                .flatMap { $0.contains("${") ? nil : $0 } ?? interfaceName
            let urlExpression = isFeign ? annotationArgs["url"] : (annotationArgs["url"] ?? annotationArgs["value"])
            let url = urlExpression.map { URLExpression.evaluate($0, source: source, index: index) }
            var prefix = annotationArgs["path"].map { URLExpression.evaluate($0, source: source, index: index) }

            // Arayüz düzeyinde @RequestMapping("/x")
            let header = source.slice(match.offset..<open)
            if let mapping = header.range(of: "@RequestMapping") {
                let rest = String(header[mapping.upperBound...])
                if rest.hasPrefix("("), let end = rest.firstIndex(of: ")") {
                    let args = JavaSyntax.annotationArguments(String(rest[rest.index(after: rest.startIndex)..<end]))
                    if let value = args["value"] ?? args["path"] {
                        prefix = URLExpression.evaluate(JavaSyntax.firstArrayElement(value), source: source, index: index)
                    }
                }
            }

            let (variable, origin, basePath) = baseAddress(clientName: clientName, url: url)
            for member in members(of: source, body: (open + 1)..<close) {
                guard let call = operation(
                    member, source: source, index: index,
                    client: clientName, source: isFeign ? .feign : .httpExchange,
                    variable: variable, origin: origin,
                    basePath: basePath + (prefix.map(render) ?? "")
                ) else { continue }
                calls.append(call)
            }
        }
        return calls
    }

    /// Feign url'si: `${partner.url}` → ayar; `https://x` → kod; yok → servis keşfi.
    static func baseAddress(clientName: String, url: URLExpression?) -> (String, OutboundCall.Origin, String) {
        let variable = slug(clientName)
        guard let url, let first = url.segments.first else { return (variable, .unknown, "") }
        let rest = render(URLExpression(segments: Array(url.segments.dropFirst())))
        switch first {
        case .property(let placeholder):
            return (variable, .property(placeholder), rest)
        case .literal(let text):
            let (origin, path) = splitOrigin(text)
            if let origin { return (variable, .literal(origin), path + rest) }
            return (variable, .unknown, text + rest)
        case .runtime:
            return (variable, .unknown, render(url))
        }
    }

    /// `https://host:8080/api` → ("https://host:8080", "/api")
    static func splitOrigin(_ text: String) -> (String?, String) {
        guard let schemeEnd = text.range(of: "://") else { return (nil, text) }
        let afterScheme = text[schemeEnd.upperBound...]
        let slash = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
        return (String(text[..<slash]), String(text[slash...]))
    }

    /// Arayüz gövdesindeki üye bildirimleri (metotlar); iç içe gövdeler atlanır.
    static func members(of source: JavaSource, body: Range<Int>) -> [(text: String, offset: Int)] {
        var members: [(String, Int)] = []
        var start = body.lowerBound
        var index = body.lowerBound
        while index < body.upperBound {
            let character = source.code[index]
            if character == "\"" || character == "'" {
                index = JavaSource.skipQuotedPublic(source.code, from: index, quote: character)
                continue
            }
            if character == "(" || character == "{" {
                // Annotation argümanları ve imza parantezleri atlanır; süslü gövde
                // (default metot, iç tür) üyeyi bitirir.
                guard let end = source.matching(from: index) else { break }
                if character == "{" {
                    members.append((source.slice(start..<index), start))
                    start = end + 1
                }
                index = end + 1
                continue
            }
            if character == ";" {
                members.append((source.slice(start..<index), start))
                start = index + 1
            }
            index += 1
        }
        return members.filter { $0.0.contains("(") }
    }

    static let mappingMethods: [String: HTTPMethod] = [
        "GetMapping": .get, "PostMapping": .post, "PutMapping": .put, "DeleteMapping": .delete, "PatchMapping": .patch,
        "GetExchange": .get, "PostExchange": .post, "PutExchange": .put, "DeleteExchange": .delete, "PatchExchange": .patch,
    ]

    static func operation(
        _ member: (text: String, offset: Int),
        source javaSource: JavaSource,
        index: ProjectIndex,
        client: String,
        source kind: OutboundCall.Source,
        variable: String,
        origin: OutboundCall.Origin,
        basePath: String
    ) -> OutboundCall? {
        var (annotations, signature) = Annotations.read(member.text)
        var method: HTTPMethod?
        var path = ""
        var headers: [KeyValueEntry] = []
        var complete = true

        for annotation in annotations {
            if let mapped = mappingMethods[annotation.name] {
                method = mapped
            } else if annotation.name == "RequestMapping" || annotation.name == "HttpExchange" {
                let raw = annotation.args["method"].map(JavaSyntax.firstArrayElement) ?? ""
                let name = raw.split(separator: ".").last.map { String($0).replacingOccurrences(of: "\"", with: "").uppercased() } ?? ""
                method = HTTPMethod(rawValue: name) ?? .get
            } else if annotation.name == "RequestLine", let line = annotation.args["value"].flatMap(JavaSyntax.stringLiteral) {
                // Feign'in kendi sözdizimi: "GET /x/{id}"
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                method = HTTPMethod(rawValue: parts.first?.uppercased() ?? "") ?? .get
                path = parts.count > 1 ? render(URLExpression(segments: URLExpression.literalSegments(parts[1]))) : ""
                continue
            } else {
                continue
            }
            let value = annotation.args["value"] ?? annotation.args["path"] ?? annotation.args["url"]
            if let value {
                let expression = URLExpression.evaluate(JavaSyntax.firstArrayElement(value), source: javaSource, index: index)
                path = render(expression)
                complete = complete && expression.isComplete
            }
            if let consumes = annotation.args["consumes"].map(JavaSyntax.firstArrayElement) {
                headers.append(KeyValueEntry(key: "Content-Type", value: mediaType(consumes, source: javaSource, index: index)))
            }
            if let produces = annotation.args["produces"].map(JavaSyntax.firstArrayElement) {
                headers.append(KeyValueEntry(key: "Accept", value: mediaType(produces, source: javaSource, index: index)))
            }
        }
        guard let method, let open = signature.firstIndex(of: "(") else { return nil }
        let name = signature[..<open].split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).last.map(String.init) ?? "istek"
        guard let close = signature.lastIndex(of: ")"), close > open else { return nil }
        signature = String(signature[signature.index(after: open)..<close])

        var query: [KeyValueEntry] = []
        var bodyType: String?
        for parameter in JavaSyntax.splitTopLevel(signature) where !parameter.isEmpty {
            let (paramAnnotations, declaration) = Annotations.read(parameter)
            let words = declaration.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init).filter { $0 != "final" }
            guard let paramName = words.last else { continue }
            let paramType = words.dropLast().joined(separator: " ")
            let annotation = paramAnnotations.first { ["PathVariable", "RequestParam", "RequestHeader", "RequestBody", "Param", "SpringQueryMap", "QueryMap", "RequestPart", "CookieValue"].contains($0.name) }
            let declared = (annotation?.args["value"] ?? annotation?.args["name"]).flatMap(JavaSyntax.stringLiteral) ?? paramName
            let required = annotation?.args["required"]?.trimmingCharacters(in: .whitespaces) != "false" && annotation?.args["defaultValue"] == nil
            switch annotation?.name {
            case "RequestParam":
                query.append(KeyValueEntry(key: declared, value: "", enabled: required))
            case "RequestHeader":
                headers.append(KeyValueEntry(key: declared, value: "", enabled: required))
            case "RequestBody":
                bodyType = paramType
            case "PathVariable", "Param", "CookieValue", "SpringQueryMap", "QueryMap", "RequestPart":
                break
            default:
                // Feign'de işaretsiz parametre gövdedir; URI ya da başlık türleri hariç.
                if method != .get, method != .delete, !["URI", "HttpHeaders", "Map<String, String>"].contains(paramType) {
                    bodyType = paramType
                }
            }
        }
        if bodyType != nil, !headers.contains(where: { $0.key == "Content-Type" }) {
            headers.append(KeyValueEntry(key: "Content-Type", value: "application/json"))
        }
        return OutboundCall(
            source: kind,
            client: client,
            operation: name,
            method: method,
            baseVariable: variable,
            baseOrigin: origin,
            path: normalizePath(basePath + path),
            query: query,
            headers: headers,
            bodyType: bodyType,
            bodySample: bodyType.flatMap(index.sampleJSON(forType:)),
            location: javaSource.location(member.offset + (member.text.count - member.text.drop { $0.isWhitespace }.count)),
            isComplete: complete && origin != .unknown
        )
    }

    static func mediaType(_ expression: String, source: JavaSource, index: ProjectIndex) -> String {
        if let literal = JavaSyntax.stringLiteral(expression) { return literal }
        let name = expression.split(separator: ".").last.map(String.init) ?? expression
        switch name.replacingOccurrences(of: "_VALUE", with: "") {
        case "APPLICATION_JSON": return "application/json"
        case "APPLICATION_FORM_URLENCODED": return "application/x-www-form-urlencoded"
        case "MULTIPART_FORM_DATA": return "multipart/form-data"
        case "TEXT_PLAIN": return "text/plain"
        case "APPLICATION_XML": return "application/xml"
        default: return "application/json"
        }
    }

    private static func nextNonSpace(_ source: JavaSource, from start: Int) -> Int? {
        var index = start
        while index < source.code.count, source.code[index].isWhitespace { index += 1 }
        return index < source.code.count ? index : nil
    }
}

/// `@Ad(argümanlar)` dizisini okur; kalan metni döner.
enum Annotations {
    struct Annotation {
        let name: String
        let args: [String: String]
    }

    static func read(_ text: String) -> ([Annotation], String) {
        var annotations: [Annotation] = []
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while rest.hasPrefix("@"), !rest.hasPrefix("@interface") {
            let nameEnd = rest.dropFirst().firstIndex { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") } ?? rest.endIndex
            let fullName = String(rest[rest.index(after: rest.startIndex)..<nameEnd])
            var after = rest[nameEnd...].drop { $0.isWhitespace }
            var args: [String: String] = [:]
            if after.first == "(" {
                var depth = 0
                var closing: Substring.Index?
                var quote: Character?
                for index in after.indices {
                    let character = after[index]
                    if let active = quote {
                        if character == active, index > after.startIndex, after[after.index(before: index)] != "\\" { quote = nil }
                        continue
                    }
                    if character == "\"" { quote = character; continue }
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1; if depth == 0 { closing = index; break } }
                }
                // Kapanmamış annotation: kalan metin annotation sayılmaz.
                guard let end = closing else { break }
                args = JavaSyntax.annotationArguments(String(after[after.index(after: after.startIndex)..<end]))
                after = after[after.index(after: end)...]
            }
            annotations.append(Annotation(name: fullName.split(separator: ".").last.map(String.init) ?? fullName, args: args))
            rest = after.drop { $0.isWhitespace }
        }
        return (annotations, String(rest))
    }
}

// MARK: - RestTemplate, WebClient, RestClient

enum TemplateCalls {
    static let restTemplateMethods: [String: HTTPMethod?] = [
        "getForObject": .get, "getForEntity": .get,
        "postForObject": .post, "postForEntity": .post, "postForLocation": .post,
        "put": .put, "patchForObject": .patch, "delete": .delete,
        "headForHeaders": .head, "optionsForAllow": .options,
        "exchange": nil, "execute": nil,
    ]

    static func find(in source: JavaSource, index: ProjectIndex) -> [OutboundCall] {
        var found: [OutboundCall] = []
        let clients = declaredClients(in: source)
        let fileBase = ProjectIndex.baseExpression(in: source.text)

        // RestTemplate
        let names = restTemplateMethods.keys.joined(separator: "|")
        for match in source.matches(#"\b([A-Za-z_]\w*)\s*\.\s*("# + names + #")\s*\("#) {
            let receiver = match.groups[0]
            guard clients[receiver] == "RestTemplate" || (clients[receiver] == nil && receiver.lowercased().contains("resttemplate")) else { continue }
            guard let open = openParen(in: source, from: match.offset), let close = source.matching(from: open) else { continue }
            let arguments = JavaSyntax.splitTopLevel(source.slice((open + 1)..<close))
            guard let urlArgument = arguments.first else { continue }
            var method = restTemplateMethods[match.groups[1]] ?? nil
            var bodyExpression: String?
            if method == nil, arguments.count > 1 {
                let raw = arguments[1].split(separator: ".").last.map(String.init) ?? ""
                method = HTTPMethod(rawValue: raw.uppercased())
                bodyExpression = arguments.count > 2 ? arguments[2] : nil
            } else if [.post, .put, .patch].contains(method), arguments.count > 1 {
                bodyExpression = arguments[1]
            }
            let call = makeCall(
                kind: .restTemplate, receiver: receiver, operation: match.groups[1],
                method: method ?? .get, urlExpression: urlArgument, headers: [],
                bodyExpression: bodyExpression, offset: match.offset,
                source: source, index: index, fileBase: fileBase, clients: clients
            )
            found.append(call)
        }

        // WebClient / RestClient akıcı zincirleri
        for match in source.matches(#"\b([A-Za-z_]\w*)\s*\.\s*(get|post|put|delete|patch|head|options|method)\s*\("#) {
            let receiver = match.groups[0]
            let type = clients[receiver] ?? (receiver.lowercased().contains("webclient") ? "WebClient" : receiver.lowercased().contains("restclient") ? "RestClient" : nil)
            guard let type, type == "WebClient" || type == "RestClient" else { continue }
            guard let open = openParen(in: source, from: match.offset), let close = source.matching(from: open) else { continue }
            var method = HTTPMethod(rawValue: match.groups[1].uppercased())
            if match.groups[1] == "method" {
                let raw = source.slice((open + 1)..<close).split(separator: ".").last.map(String.init) ?? ""
                method = HTTPMethod(rawValue: raw.trimmingCharacters(in: .whitespaces).uppercased())
            }
            let chain = statement(in: source, from: close + 1)
            guard let uri = call(named: "uri", in: chain) else { continue }
            var headers: [KeyValueEntry] = []
            for header in calls(named: "header", in: chain) {
                let parts = JavaSyntax.splitTopLevel(header)
                if let name = parts.first.flatMap(JavaSyntax.stringLiteral) {
                    headers.append(KeyValueEntry(key: name, value: parts.count > 1 ? (JavaSyntax.stringLiteral(parts[1]) ?? "") : ""))
                }
            }
            if let contentType = call(named: "contentType", in: chain) {
                headers.append(KeyValueEntry(key: "Content-Type", value: DeclarativeClients.mediaType(contentType, source: source, index: index)))
            }
            let bodyExpression = call(named: "bodyValue", in: chain) ?? call(named: "body", in: chain)
            found.append(makeCall(
                kind: type == "WebClient" ? .webClient : .restClient, receiver: receiver, operation: match.groups[1],
                method: method ?? .get, urlExpression: uri, headers: headers,
                bodyExpression: bodyExpression, offset: match.offset,
                source: source, index: index, fileBase: fileBase, clients: clients
            ))
        }
        return found
    }

    /// Dosyada türü belli istemci alanları/değişkenleri: ad → tür.
    static func declaredClients(in source: JavaSource) -> [String: String] {
        var result: [String: String] = [:]
        for match in source.matches(#"\b(RestTemplate|WebClient|RestClient)\s+([A-Za-z_]\w*)\s*[;=,)]"#) {
            result[match.groups[1]] = match.groups[0]
        }
        return result
    }

    static func makeCall(
        kind: OutboundCall.Source, receiver: String, operation: String, method: HTTPMethod,
        urlExpression: String, headers: [KeyValueEntry], bodyExpression: String?, offset: Int,
        source: JavaSource, index: ProjectIndex, fileBase: String?, clients: [String: String]
    ) -> OutboundCall {
        var url = uriExpression(urlExpression, source: source, index: index)
        var query = url.query
        // Temel adres: ifadenin kendisi, ayar anahtarıyla ya da mutlak adresle
        // başlıyorsa oradan; değilse istemcinin baseUrl/rootUri'sinden.
        var variable = slug(receiver)
        var origin: OutboundCall.Origin = .unknown
        var segments = url.expression.segments
        if case .property(let placeholder)? = segments.first {
            variable = slug(propertyKey(placeholder))
            origin = .property(placeholder)
            segments.removeFirst()
        } else if case .literal(let text)? = segments.first, case (let found?, let path) = DeclarativeClients.splitOrigin(text) {
            variable = slug(URL(string: found)?.host ?? found)
            origin = .literal(found)
            segments[0] = .literal(path)
        } else if let (base, baseSource) = beanBase(for: receiver, type: clients[receiver], index: index)
                    ?? fileBase.map({ ($0, source) }) {
            let baseURL = URLExpression.evaluate(base, source: baseSource, index: index)
            switch baseURL.segments.first {
            case .property(let placeholder)?:
                variable = slug(propertyKey(placeholder)); origin = .property(placeholder)
                segments = Array(baseURL.segments.dropFirst()) + segments
            case .literal(let text)?:
                let (found, path) = DeclarativeClients.splitOrigin(text)
                if let found { variable = slug(URL(string: found)?.host ?? found); origin = .literal(found) }
                segments = [.literal(path)] + Array(baseURL.segments.dropFirst()) + segments
            default:
                break
            }
        }
        url.expression.segments = segments
        if query.isEmpty, let (path, parsed) = splitQuery(render(url.expression)) {
            url.expression.segments = [.literal(path)]
            query = parsed
        }
        let bodyType = bodyExpression.flatMap { inferType($0, in: source) }
        var allHeaders = headers
        if bodyType != nil, !allHeaders.contains(where: { $0.key == "Content-Type" }) {
            allHeaders.append(KeyValueEntry(key: "Content-Type", value: "application/json"))
        }
        return OutboundCall(
            source: kind,
            client: receiver,
            operation: operation,
            method: method,
            baseVariable: variable,
            baseOrigin: origin,
            path: normalizePath(render(url.expression)),
            query: query,
            headers: allHeaders,
            bodyType: bodyType,
            bodySample: bodyType.flatMap(index.sampleJSON(forType:)),
            location: source.location(offset),
            isComplete: url.expression.isComplete && origin != .unknown
        )
    }

    /// `.uri("/x/{id}", id)` ya da `.uri(b -> b.path("/x").queryParam("a", a).build())`
    static func uriExpression(_ raw: String, source: JavaSource, index: ProjectIndex) -> (expression: URLExpression, query: [KeyValueEntry]) {
        let arguments = JavaSyntax.splitTopLevel(raw)
        guard let first = arguments.first else { return (URLExpression(segments: [.runtime("deger")], isComplete: false), []) }
        if first.contains("->") {
            var expression = URLExpression()
            for path in calls(named: "path", in: first) {
                let part = URLExpression.evaluate(path, source: source, index: index)
                expression.segments += part.segments
                expression.isComplete = expression.isComplete && part.isComplete
            }
            let query = calls(named: "queryParam", in: first).compactMap { call -> KeyValueEntry? in
                JavaSyntax.splitTopLevel(call).first.flatMap(JavaSyntax.stringLiteral).map { KeyValueEntry(key: $0, value: "") }
            }
            return (expression, query)
        }
        return (URLExpression.evaluate(first, source: source, index: index), [])
    }

    /// İstemcinin `@Bean` tanımındaki baseUrl: ada göre, yoksa aynı türde tek bean varsa o.
    static func beanBase(for receiver: String, type: String?, index: ProjectIndex) -> (String, JavaSource)? {
        let bean = index.clientBeans[receiver] ?? {
            let sameType = index.clientBeans.values.filter { $0.type == type }
            return sameType.count == 1 ? sameType.first : nil
        }()
        guard let bean, let source = index.sourcesByPath[bean.file] else { return nil }
        return (bean.baseExpression, source)
    }

    /// `new X(...)`, `new HttpEntity<>(dto, h)`, tanımı dosyada olan değişken.
    static func inferType(_ expression: String, in source: JavaSource, depth: Int = 0) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard depth < 4, !trimmed.isEmpty, trimmed != "null" else { return nil }
        if trimmed.hasPrefix("new "), let open = trimmed.firstIndex(of: "(") {
            let type = trimmed.dropFirst(4)[..<open].trimmingCharacters(in: .whitespaces)
            if type.hasPrefix("HttpEntity") || type.hasPrefix("RequestEntity") {
                return innerArguments(trimmed).flatMap { JavaSyntax.splitTopLevel($0).first }
                    .flatMap { inferType($0, in: source, depth: depth + 1) }
            }
            return type.replacingOccurrences(of: "<>", with: "")
        }
        if trimmed.hasPrefix("BodyInserters.fromValue("), let inner = innerArguments(trimmed) {
            return inferType(inner, in: source, depth: depth + 1)
        }
        guard trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        let declarations = source.matches(#"\b([A-Z][\w.]*(?:<[^;=()]*>)?)\s+"# + trimmed + #"\s*[=;,)]"#)
        guard let type = declarations.first?.groups[0], !["HttpEntity", "RequestEntity", "var"].contains(where: type.hasPrefix) else {
            if let entity = declarations.first?.groups[0], entity.hasPrefix("HttpEntity<") {
                return String(entity.dropFirst("HttpEntity<".count).dropLast())
            }
            return nil
        }
        return type
    }

    private static func openParen(in source: JavaSource, from offset: Int) -> Int? {
        var index = offset
        while index < source.code.count, source.code[index] != "(" { index += 1 }
        return index < source.code.count ? index : nil
    }

    /// Zincirin sonuna (üst düzey `;`) kadar olan metin.
    static func statement(in source: JavaSource, from start: Int) -> String {
        var depth = 0
        var index = start
        let limit = min(source.code.count, start + 4000)
        while index < limit {
            let character = source.code[index]
            if character == "(" || character == "{" { depth += 1 }
            if character == ")" || character == "}" { depth -= 1; if depth < 0 { break } }
            if character == ";", depth == 0 { break }
            index += 1
        }
        return source.slice(start..<index)
    }

    static func call(named name: String, in chain: String) -> String? {
        calls(named: name, in: chain).first
    }

    /// Zincirdeki `.ad(…)` çağrılarının argümanları.
    static func calls(named name: String, in chain: String) -> [String] {
        var results: [String] = []
        var searchStart = chain.startIndex
        while let range = chain.range(of: ".\(name)(", range: searchStart..<chain.endIndex) {
            var depth = 1
            var index = range.upperBound
            while index < chain.endIndex {
                if chain[index] == "(" { depth += 1 }
                if chain[index] == ")" { depth -= 1; if depth == 0 { break } }
                index = chain.index(after: index)
            }
            results.append(String(chain[range.upperBound..<index]))
            searchStart = index < chain.endIndex ? chain.index(after: index) : chain.endIndex
        }
        return results
    }

    /// Adresteki sabit `?a=1&b` kısmını query satırlarına ayırır.
    static func splitQuery(_ path: String) -> (String, [KeyValueEntry])? {
        guard let mark = path.firstIndex(of: "?") else { return nil }
        let query = path[path.index(after: mark)...].split(separator: "&").compactMap { pair -> KeyValueEntry? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { return nil }
            return KeyValueEntry(key: key, value: parts.count > 1 ? parts[1] : "")
        }
        return (String(path[..<mark]), query)
    }
}

// MARK: - Ortak

/// Segmentleri Secora şablonuna çevirir: ayar → `{{anahtar}}`, çalışma anı → `{{ad}}`.
func render(_ expression: URLExpression) -> String {
    expression.segments.map { segment in
        switch segment {
        case .literal(let text): return text
        case .property(let placeholder): return "{{\(slug(propertyKey(placeholder)))}}"
        case .runtime(let name): return "{{\(name)}}"
        }
    }.joined()
}

/// `f(a, b)` → `a, b`; parantez dengesizse nil (yarım ifade).
func innerArguments(_ call: String) -> String? {
    guard let open = call.firstIndex(of: "("), call.hasSuffix(")") else { return nil }
    let start = call.index(after: open)
    let end = call.index(before: call.endIndex)
    return start <= end ? String(call[start..<end]) : nil
}

/// `partner.url:http://x` → `partner.url`
func propertyKey(_ placeholder: String) -> String {
    SpringConfig.splitPlaceholder(placeholder).0
}

func normalizePath(_ path: String) -> String {
    var result = path.replacingOccurrences(of: "//", with: "/")
    if !result.isEmpty, !result.hasPrefix("/"), !result.hasPrefix("{{") { result = "/" + result }
    return result
}

func slug(_ text: String) -> String {
    OpenAPIImporter.slug(text).isEmpty ? "servis" : OpenAPIImporter.slug(text)
}

extension JavaSource {
    static func skipQuotedPublic(_ input: [Character], from start: Int, quote: Character) -> Int {
        var index = start + 1
        while index < input.count {
            if input[index] == "\\" { index += 2; continue }
            if input[index] == quote || input[index] == "\n" { return index + 1 }
            index += 1
        }
        return input.count
    }
}
