import Foundation

/// Kaynak kod taramasından koleksiyon ve environment değişkenleri üretir.
public enum OutboundCollectionBuilder {
    /// Bir dış servisin temel adres değişkeni.
    public struct Variable: Identifiable, Hashable, Sendable {
        public enum Status: Hashable, Sendable {
            case value(String)
            /// Ayar değeri kimlik bilgisi içeriyor; kopyalanmaz.
            case sensitive
            /// Değer bulunamadı; kullanıcı girer.
            case missing(reason: String)
        }

        public let name: String
        public let status: Status
        /// Kullanıcıya nereden geldiği: `partner.customer.url`, "kodda", "servis keşfi".
        public let origin: String

        public var id: String { name }

        public var value: String? {
            if case .value(let value) = status { return value }
            return nil
        }
    }

    public static func variables(for result: OutboundScanResult, profile: String?) -> [Variable] {
        var seen = Set<String>()
        var variables: [Variable] = []
        for call in result.calls where seen.insert(call.baseVariable).inserted {
            variables.append(variable(for: call, config: result.config, profile: profile))
        }
        return variables.sorted { $0.name < $1.name }
    }

    static func variable(for call: OutboundCall, config: SpringConfig, profile: String?) -> Variable {
        switch call.baseOrigin {
        case .property(let placeholder):
            let (key, fallback) = SpringConfig.splitPlaceholder(placeholder)
            // Spring gibi: anahtar ayarlarda yoksa @Value/${…:varsayılan} değeri.
            guard let raw = config.value(for: key, profile: profile) ?? fallback.map({ config.resolve($0, profile: profile) }) else {
                return Variable(name: call.baseVariable, status: .missing(reason: L10n.t("outbound.reason.notInConfig")), origin: key)
            }
            if raw.contains("${") {
                return Variable(name: call.baseVariable, status: .missing(reason: L10n.t("outbound.reason.runtime")), origin: key)
            }
            if isSensitive(key: key, value: raw) {
                return Variable(name: call.baseVariable, status: .sensitive, origin: key)
            }
            return Variable(name: call.baseVariable, status: .value(trimSlash(raw)), origin: key)
        case .literal(let address):
            return Variable(name: call.baseVariable, status: .value(trimSlash(address)), origin: L10n.t("outbound.origin.code"))
        case .unknown:
            return Variable(name: call.baseVariable, status: .missing(reason: L10n.t("outbound.reason.discovery")), origin: L10n.t("outbound.origin.unknown"))
        }
    }

    /// Adında parola/secret geçen ya da adresinde kullanıcı:parola olan ayar.
    static func isSensitive(key: String, value: String) -> Bool {
        let normalized = SpringConfig.normalize(key)
        let keywords = ["password", "secret", "token", "apikey", "credential", "privatekey"]
        if keywords.contains(where: normalized.contains) { return true }
        if let url = URL(string: value), url.user != nil || url.password != nil { return true }
        return false
    }

    private static func trimSlash(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespaces)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    // MARK: - Koleksiyon

    public static func makeCollection(
        from result: OutboundScanResult,
        variables: [Variable],
        existingNames: [String]
    ) throws -> CollectionPorting.ImportOutcome {
        var usedNames = Set<String>()
        let requests = result.calls.map { call -> RequestModel in
            var name = requestName(for: call)
            if !call.isComplete { name += L10n.t("outbound.incompleteSuffix") }
            var unique = name
            var counter = 2
            while !usedNames.insert(unique).inserted {
                unique = "\(name) (\(counter))"
                counter += 1
            }
            var request = RequestModel(
                name: unique,
                method: call.method,
                url: "{{\(call.baseVariable)}}\(call.path)",
                headers: call.headers,
                queryParams: call.query
            )
            if let sample = call.bodySample {
                let contentType = call.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/json"
                request.body = .raw(content: sample, contentType: contentType)
            }
            return request
        }
        let (name, renamed) = try CollectionPorting.resolveName(
            L10n.t("outbound.collectionName", result.projectName),
            suffix: "2",
            existingNames: existingNames
        )
        return CollectionPorting.ImportOutcome(
            collection: CollectionModel(name: name, requests: requests),
            wasRenamed: renamed,
            warnings: notes(result: result, variables: variables)
        )
    }

    /// Feign: "istemci / metot". Şablon çağrılarında sınıf ve adres daha
    /// anlamlı: "PaymentService / POST /payments".
    public static func requestName(for call: OutboundCall) -> String {
        switch call.source {
        case .feign, .httpExchange:
            return "\(call.client) / \(call.operation)"
        case .restTemplate, .webClient, .restClient:
            let file = (call.location.split(separator: ":").first.map(String.init) ?? call.location)
            let className = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            return "\(className) / \(call.method.rawValue) \(call.path.isEmpty ? "/" : call.path)"
        }
    }

    static func notes(result: OutboundScanResult, variables: [Variable]) -> [String] {
        var notes: [String] = []
        let counts = OutboundCall.Source.allCases.compactMap { source -> String? in
            let count = result.calls.filter { $0.source == source }.count
            return count > 0 ? "\(count) \(source.rawValue)" : nil
        }
        notes.append(L10n.t("outbound.note.scanned", L10n.plural("outbound.javaFiles", count: result.javaFileCount), counts.joined(separator: ", ")))
        for variable in variables {
            switch variable.status {
            case .value:
                break
            case .sensitive:
                notes.append(L10n.t("outbound.note.credential", variable.name, variable.origin))
            case .missing(let reason):
                notes.append(L10n.t("outbound.note.missing", variable.name, reason))
            }
        }
        let incomplete = result.calls.filter { !$0.isComplete && $0.baseOrigin != .unknown }
        for call in incomplete.prefix(25) {
            notes.append(L10n.t("outbound.note.incomplete", call.location, requestName(for: call)))
        }
        if incomplete.count > 25 {
            notes.append(L10n.plural("outbound.note.more", count: incomplete.count - 25))
        }
        return notes + result.notes
    }
}
