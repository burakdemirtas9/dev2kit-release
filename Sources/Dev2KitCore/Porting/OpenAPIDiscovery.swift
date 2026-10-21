import Foundation

/// Kullanıcının verdiği adresten OpenAPI dokümanını bulur.
///
/// Adres doğrudan doküman olabileceği gibi Swagger UI sayfası da olabilir
/// (`…/swagger-ui/index.html`). Bu durumda aynı sunucuda, sayfanın bağlam
/// yolu da denenerek (gateway arkasındaki `/servis-adi/…`) bilinen adreslere bakılır.
/// Ağ erişimi dışarıdan verilir: politika, TLS ve yönlendirme kuralları
/// çağıranın istek motorunda uygulanır; burası yalnızca karar verir.
public enum OpenAPIDiscovery {
    public typealias Fetch = (URL) async throws -> Data

    public enum Outcome {
        /// Doküman bulundu.
        case document(OpenAPIImporter.Document)
        /// Springdoc birden çok grup sunuyor; kullanıcı seçer.
        case groups([Group])
    }

    public struct Group: Hashable, Identifiable, Sendable {
        public let name: String
        public let url: URL
        public var id: URL { url }
    }

    /// Fetcher'ın 2xx dışı yanıtta fırlattığı hata. Yalnızca bu (ve doküman
    /// olmayan içerik) sıradaki adresin denenmesine yol açar; güvenlik engeli,
    /// bağlantı ya da TLS hatası aramayı hemen durdurur: aynı host'ta başka
    /// yol denemek sonucu değiştirmez, yalnızca bekletir ve asıl sebebi gizler.
    public struct HTTPStatusError: Error, LocalizedError {
        public let url: URL
        public let statusCode: Int

        public init(url: URL, statusCode: Int) {
            self.url = url
            self.statusCode = statusCode
        }

        public var errorDescription: String? { "\(url.absoluteString) → HTTP \(statusCode)" }
    }

    public enum DiscoveryError: Error, LocalizedError {
        case notFound(tried: [String])

        public var errorDescription: String? {
            switch self {
            case .notFound(let tried):
                return L10n.t("openapi.notFound", tried.joined(separator: ", "))
            }
        }
    }

    /// Springdoc ve yaygın varsayılan adresler, denenme sırasıyla.
    /// `/api-docs…`: Springdoc'ta `springdoc.api-docs.path=/api-docs`
    /// (kurumsal servislerde yaygın; 2026-10-21 kullanıcı bildirimi, yalnızca
    /// `/v3/api-docs` denendiği için doküman bulunamıyordu).
    static let wellKnownPaths = [
        "/v3/api-docs/swagger-config", "/v3/api-docs",
        "/api-docs/swagger-config", "/api-docs",
        "/v2/api-docs", "/openapi.json", "/swagger.json",
    ]
    /// Bir keşifte en fazla bu kadar adres denenir: girilen adres + her
    /// bilinen yol bağlam yolunda ve kökte.
    static let maxAttempts = 1 + wellKnownPaths.count * 2

    public static func discover(from url: URL, fetch: Fetch) async throws -> Outcome {
        var tried: [String] = []

        for candidate in [url] + candidates(around: url) where !tried.contains(candidate.absoluteString) {
            guard tried.count < maxAttempts else { break }
            tried.append(candidate.absoluteString)
            let data: Data
            do {
                data = try await fetch(candidate)
            } catch is HTTPStatusError {
                continue
            }
            if let outcome = try interpret(data, from: candidate) {
                if case .single(let next) = outcome {
                    guard !tried.contains(next.absoluteString) else { continue }
                    tried.append(next.absoluteString)
                    do {
                        return .document(try OpenAPIImporter.parse(try await fetch(next), sourceURL: next))
                    } catch is HTTPStatusError {
                        continue
                    } catch let error as OpenAPIImporter.ImportError where error != .yaml {
                        continue
                    }
                }
                if case .final(let result) = outcome { return result }
            }
        }
        throw DiscoveryError.notFound(tried: tried)
    }

    private enum Interpretation {
        case final(Outcome)
        case single(URL)
    }

    /// Yanıt doküman mı, Springdoc yapılandırması mı, yoksa ilgisiz mi (HTML).
    private static func interpret(_ data: Data, from url: URL) throws -> Interpretation? {
        do {
            return .final(.document(try OpenAPIImporter.parse(data, sourceURL: url)))
        } catch OpenAPIImporter.ImportError.yaml {
            throw OpenAPIImporter.ImportError.yaml
        } catch {
            // Doküman değil; Springdoc swagger-config olabilir.
        }
        guard let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let urls = config["urls"] as? [[String: Any]] {
            let groups = urls.compactMap { entry -> Group? in
                guard let path = entry["url"] as? String, let target = URL(string: path, relativeTo: url)?.absoluteURL else { return nil }
                return Group(name: entry["name"] as? String ?? path, url: target)
            }
            if groups.count == 1 { return .single(groups[0].url) }
            if !groups.isEmpty { return .final(.groups(groups)) }
        }
        if let path = config["url"] as? String, let target = URL(string: path, relativeTo: url)?.absoluteURL {
            return .single(target)
        }
        return nil
    }

    /// `https://gw/fx-bff-service/swagger-ui/index.html` için önce
    /// `/fx-bff-service/v3/api-docs…`, sonra kök `/v3/api-docs…`.
    static func candidates(around url: URL) -> [URL] {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        components.query = nil
        components.fragment = nil
        let segments = url.path.split(separator: "/").map(String.init)
        let markers: Set<String> = ["swagger-ui", "swagger-ui.html", "v3", "v2", "api-docs", "openapi.json", "swagger.json", "index.html", "doc.html"]
        let contextSegments = Array(segments.prefix { !markers.contains($0.lowercased()) })
        var prefixes = [""]
        if !contextSegments.isEmpty { prefixes.insert("/" + contextSegments.joined(separator: "/"), at: 0) }

        var result: [URL] = []
        for prefix in prefixes {
            for path in wellKnownPaths {
                components.path = prefix + path
                if let candidate = components.url, !result.contains(candidate) { result.append(candidate) }
            }
        }
        return result
    }
}
