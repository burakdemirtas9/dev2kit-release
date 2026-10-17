import Foundation

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
                index = JavaSource.skipQuoted(source.code, from: index, quote: character)
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
