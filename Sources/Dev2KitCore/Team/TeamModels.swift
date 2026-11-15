import Foundation

/// Kurum collection'ları (2026-11-11): dev2kit-auth ve dev2kit-data servisleri.
/// Sözleşme: kurumun "dev2kit istemci entegrasyon rehberi".
///
/// Servis adresleri tek yerde. Şimdilik gömülü (kullanıcı kararı): rehber
/// adreslerin dışarıdan verilmesini istiyor; yönetici ayarına taşımak bu
/// değerin kaynağını değiştirmekten ibaret (TODO).
public struct TeamConfig: Equatable, Sendable {
    public let authBaseURL: URL
    public let dataBaseURL: URL

    public init(authBaseURL: URL, dataBaseURL: URL) {
        self.authBaseURL = authBaseURL
        self.dataBaseURL = dataBaseURL
    }

    public static let `default` = TeamConfig(
        authBaseURL: URL(string: "http://127.0.0.1:8080")!,
        dataBaseURL: URL(string: "http://127.0.0.1:8082")!
    )

    /// https zorunlu; düz http yalnızca bu Mac (lokal servisler). Parola ve
    /// token şifresiz ağdan gitmesin.
    public static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.host?.isEmpty == false
        case "http":
            guard let host = url.host?.lowercased() else { return false }
            return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
        default: return false
        }
    }
}

/// Kurum kullanıcısı (login ve refresh yanıtından).
public struct TeamIdentity: Codable, Equatable, Sendable {
    public let username: String
    public let displayName: String?
    public let group: String

    public init(username: String, displayName: String?, group: String) {
        self.username = username
        self.displayName = displayName
        self.group = group
    }
}

/// `GET /me`.
public struct TeamMe: Codable, Equatable, Sendable {
    public let username: String
    public let group: String
    public let canCreate: Bool

    public init(username: String, group: String, canCreate: Bool) {
        self.username = username
        self.group = group
        self.canCreate = canCreate
    }
}

/// `GET /collections` satırı (içerik taşımaz).
public struct TeamCollectionSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let ownerGroup: String
    public let version: Int
    public let updatedBy: String?
    public let updatedAt: String?
    public let canUpdate: Bool
    public let canDelete: Bool

    public init(id: String, name: String, ownerGroup: String, version: Int, updatedBy: String? = nil,
                updatedAt: String? = nil, canUpdate: Bool, canDelete: Bool) {
        self.id = id
        self.name = name
        self.ownerGroup = ownerGroup
        self.version = version
        self.updatedBy = updatedBy
        self.updatedAt = updatedAt
        self.canUpdate = canUpdate
        self.canDelete = canDelete
    }

    /// Aynı özet, başka sürümle (yerel düzenlemenin dayandığı sürümü korumak için).
    func withVersion(_ version: Int) -> TeamCollectionSummary {
        TeamCollectionSummary(id: id, name: name, ownerGroup: ownerGroup, version: version, updatedBy: updatedBy,
                              updatedAt: updatedAt, canUpdate: canUpdate, canDelete: canDelete)
    }
}

/// `GET /collections/{id}`: özet + collection belgesi (ham JSON nesnesi).
public struct TeamCollectionDetail: Sendable {
    public let summary: TeamCollectionSummary
    public let content: Data
}

public enum TeamError: Error, Equatable, LocalizedError, Sendable {
    // Login
    case invalidUsername
    case invalidCredentials
    case passwordChangeRequired
    case tooManyAttempts(retryAfter: Int)
    case directoryUnavailable
    // Oturum
    case notLoggedIn
    case sessionExpired
    // Collection
    case forbidden
    case notFound
    case versionConflict
    case nameTaken
    case invalidName
    case contentTooLarge
    case plaintextCredentials([String])
    /// İçerik bu sürümün tanıdığı biçimde değil; açılmadı (boş sayılmaz).
    case unsupportedContent
    // Genel
    case invalidRequest
    case insecureURL
    case blockedByPolicy(String)
    case unreachable(String)
    case http(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidUsername: return L10n.t("team.error.invalidUsername")
        case .invalidCredentials: return L10n.t("team.error.invalidCredentials")
        case .passwordChangeRequired: return L10n.t("team.error.passwordChangeRequired")
        case .tooManyAttempts(let seconds): return L10n.t("team.error.tooManyAttempts", L10n.number(seconds))
        case .directoryUnavailable: return L10n.t("team.error.directoryUnavailable")
        case .notLoggedIn: return L10n.t("team.error.notLoggedIn")
        case .sessionExpired: return L10n.t("team.error.sessionExpired")
        case .forbidden: return L10n.t("team.error.forbidden")
        case .notFound: return L10n.t("team.error.notFound")
        case .versionConflict: return L10n.t("team.error.versionConflict")
        case .nameTaken: return L10n.t("team.error.nameTaken")
        case .invalidName: return L10n.t("team.error.invalidName")
        case .contentTooLarge: return L10n.t("team.error.contentTooLarge", TextStats.size(TeamCollectionCodec.maxSaveBytes))
        case .plaintextCredentials(let places): return L10n.t("team.error.plaintextCredentials", places.joined(separator: ", "))
        case .unsupportedContent: return L10n.t("team.error.unsupportedContent")
        case .invalidRequest: return L10n.t("team.error.invalidRequest")
        case .insecureURL: return L10n.t("team.error.insecureURL")
        case .blockedByPolicy(let reason): return L10n.t("team.error.blockedByPolicy", reason)
        case .unreachable(let reason): return L10n.t("team.error.unreachable", reason)
        case .http(let code): return L10n.t("team.error.http", String(code))
        case .invalidResponse: return L10n.t("team.error.invalidResponse")
        }
    }
}

/// Servis tarihleri: ISO 8601, mikro saniyeli olabilir ("…48.642238Z").
enum TeamDate {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        // Kesir 3 haneden uzunsa kırpılır (biçimleyici milisaniye bekliyor).
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = text[text.index(after: dot)..<zone].prefix(3)
            if let date = fractional.date(from: String(text[..<dot]) + "." + digits + String(text[zone...])) { return date }
        }
        let plain = ISO8601DateFormatter()
        return plain.date(from: text)
    }
}
