import Foundation

/// Postman resmî API'si (api.getpostman.com) üzerinden koleksiyon çeker.
/// Uygulamanın kullanıcı hedefli istekler dışında konuştuğu tek dış servis;
/// yalnızca kullanıcının kendi API anahtarıyla, açık isteği üzerine çağrılır.
public struct PostmanAPIClient: Sendable {
    public struct CollectionSummary: Decodable, Identifiable, Sendable, Hashable {
        public let id: String
        public let name: String

        private enum CodingKeys: String, CodingKey {
            case id = "uid"
            case name
        }
    }

    public enum APIError: Error, LocalizedError {
        case unauthorized
        case http(Int)
        case invalidResponse
        case blockedByPolicy(String)

        public var errorDescription: String? {
            switch self {
            case .blockedByPolicy(let reason):
                return L10n.t("postmanAPI.connection", reason)
            case .unauthorized:
                return L10n.t("postmanAPI.unauthorized")
            case .http(let code):
                return L10n.t("postmanAPI.http", String(code))
            case .invalidResponse:
                return L10n.t("postmanAPI.unexpected")
            }
        }
    }

    private let session: URLSession
    private let baseURL = URL(string: "https://api.getpostman.com")!

    /// Postman API'si de dışarıya giden bir bağlantı: yönetici politikası
    /// api.getpostman.com'a izin vermiyorsa hesap bağlantısı kurulmaz.
    private let hostPolicy: @Sendable () -> HostPolicyState

    public init(timeout: TimeInterval = 30, hostPolicy: @escaping @Sendable () -> HostPolicyState = { HostPolicyLoader.load() }) {
        self.hostPolicy = hostPolicy
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }

    public func listCollections(apiKey: String) async throws -> [CollectionSummary] {
        struct ListResponse: Decodable {
            let collections: [CollectionSummary]
        }
        let data = try await get(path: "collections", apiKey: apiKey)
        guard let response = try? JSONDecoder().decode(ListResponse.self, from: data) else {
            throw APIError.invalidResponse
        }
        return response.collections.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Koleksiyonun v2.1 JSON'unu döner; `CollectionPorting.importPostman` bunu işler.
    public func fetchCollectionData(uid: String, apiKey: String) async throws -> Data {
        try await get(path: "collections/\(uid)", apiKey: apiKey)
    }

    private func get(path: String, apiKey: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        Dev2KitIdentity.stamp(&request)
        let policy = hostPolicy()
        if let violation = policy.violation(for: request.url) {
            throw APIError.blockedByPolicy(violation)
        }
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        let guardian = PolicyRedirectGuard(policy: policy)
        let (data, response) = try await session.data(for: request, delegate: guardian)
        // X-Api-Key başka bir kaynağa taşınmaz (F3).
        if let blocked = guardian.blockedDestination {
            throw APIError.blockedByPolicy(L10n.t("redirect.blockedCredential", blocked.host ?? blocked.absoluteString))
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw APIError.unauthorized
        default:
            throw APIError.http(http.statusCode)
        }
    }
}
