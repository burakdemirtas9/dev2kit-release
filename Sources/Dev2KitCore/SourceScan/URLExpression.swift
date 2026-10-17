import Foundation

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

// MARK: - Ortak

/// Segmentleri dev2kit şablonuna çevirir: ayar → `{{anahtar}}`, çalışma anı → `{{ad}}`.
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
