import Foundation

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
