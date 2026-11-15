import Foundation
@testable import Dev2KitCore

/// Testler için dev2kit-auth + dev2kit-data taklidi (kurum rehberine göre),
/// tek portta. Rehberdeki davranışlar:
/// - refresh token her kullanımda değişir; eski token tekrar gelirse oturum
///   tamamen iptal edilir (çalınma sayılır),
/// - 5 hatalı login → 429 + Retry-After,
/// - collection izinleri gruba göre, güncelleme `version` ile (409).
final class FakeTeamService: @unchecked Sendable {
    private let lock = NSLock()
    private var server: LoopbackHTTPServer!
    private(set) var port: UInt16 = 0

    // Durum (lock ile)
    private var users: [String: (password: String, group: String, display: String)] = [
        "alice": ("alice-local-only", "gf-payments", "Alice Admin"),
        "bob": ("bob-local-only", "gf-cards", "Bob"),
        "frank": ("frank-local-only", "gf-dev", "Frank"),
    ]
    private var failedLogins: [String: Int] = [:]
    private var validAccess: [String: String] = [:]          // token → user
    private var validRefresh: [String: String] = [:]         // token → user
    private var usedRefresh: [String: String] = [:]          // eski token → user
    private var counter = 0
    private var collections: [String: (name: String, owner: String, version: Int, content: [String: Any], updatedBy: String)] = [:]
    var groupOverride: [String: String] = [:]
    var accessTokenLifetime: TimeInterval = 900

    // Gözlem
    private(set) var refreshCalls = 0
    private(set) var loginCalls = 0
    private(set) var dataRequestsWithRefreshToken = 0
    private(set) var log: [String] = []

    var config: TeamConfig {
        let url = URL(string: "http://127.0.0.1:\(port)")!
        return TeamConfig(authBaseURL: url, dataBaseURL: url)
    }

    func start() async throws {
        server = try LoopbackHTTPServer { [unowned self] raw in self.handle(raw) }
        port = try await server.start()
    }

    /// Bütün access token'ları geçersiz kılar (süre doldu benzetimi).
    func expireAccessTokens() {
        lock.lock(); validAccess = [:]; lock.unlock()
    }

    func seed(id: String, name: String, owner: String, content: [String: Any] = ["requests": []]) {
        lock.lock(); collections[id] = (name, owner, 0, content, "seed"); lock.unlock()
    }

    // MARK: İşleyici

    private func handle(_ raw: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let head = raw.components(separatedBy: "\r\n\r\n").first ?? ""
        let body = raw.range(of: "\r\n\r\n").map { String(raw[$0.upperBound...]) } ?? ""
        let line = head.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]) : ""
        log.append("\(method) \(path)")
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let bearer = head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("authorization: bearer ") }
            .map { String($0.dropFirst("authorization: bearer ".count)) }

        // Refresh token (değeri "refresh-…") veri servisine hiç gitmemeli.
        if !path.hasPrefix("/auth/"), raw.contains("refresh-") {
            dataRequestsWithRefreshToken += 1
        }

        switch (method, path) {
        case ("POST", "/auth/login"):
            loginCalls += 1
            let username = json["username"] as? String ?? ""
            if (failedLogins[username] ?? 0) >= 5 {
                return Self.response(429, ["code": "TOO_MANY_ATTEMPTS"], headers: ["Retry-After": "42"])
            }
            if username == "carol" { return Self.response(401, ["code": "INVALID_CREDENTIALS"]) }
            if username == "pat" { return Self.response(403, ["code": "PASSWORD_CHANGE_REQUIRED"]) }
            guard let user = users[username], user.password == json["password"] as? String else {
                failedLogins[username, default: 0] += 1
                return Self.response(401, ["code": "INVALID_CREDENTIALS"])
            }
            return issue(for: username)
        case ("POST", "/auth/refresh"):
            refreshCalls += 1
            let token = json["refreshToken"] as? String ?? ""
            if let user = usedRefresh[token] {
                // Eski token: çalınma sayılır, oturumun tamamı iptal.
                validRefresh = validRefresh.filter { $0.value != user }
                validAccess = validAccess.filter { $0.value != user }
                return Self.response(401, ["code": "INVALID_REFRESH_TOKEN"])
            }
            guard let user = validRefresh.removeValue(forKey: token) else {
                return Self.response(401, ["code": "INVALID_REFRESH_TOKEN"])
            }
            usedRefresh[token] = user
            return issue(for: user)
        case ("POST", "/auth/logout"):
            if let token = json["refreshToken"] as? String { validRefresh[token] = nil }
            return Self.response(204, nil)
        default:
            break
        }

        guard let token = bearer, let user = validAccess[token] else { return Self.response(401, nil) }
        let group = groupOverride[user] ?? users[user]!.group
        let canWrite = group != "gf-dev"

        if method == "GET", path == "/me" {
            return Self.response(200, ["username": user, "group": group, "canCreate": canWrite])
        }
        if method == "GET", path == "/collections" {
            let items = collections.sorted { $0.key < $1.key }.map { id, c in summary(id, c, group: group) }
            return Self.response(200, items)
        }
        if method == "POST", path == "/collections" {
            guard canWrite else { return Self.response(403, ["code": "FORBIDDEN"]) }
            let name = json["name"] as? String ?? ""
            if collections.values.contains(where: { $0.name == name && $0.owner == group }) {
                return Self.response(409, ["code": "NAME_TAKEN"])
            }
            counter += 1
            let id = "c-\(counter)"
            collections[id] = (name, group, 0, json["content"] as? [String: Any] ?? [:], user)
            return Self.response(201, detail(id, group: group))
        }
        let id = String(path.dropFirst("/collections/".count))
        guard path.hasPrefix("/collections/"), let current = collections[id] else { return Self.response(404, ["code": "NOT_FOUND"]) }
        switch method {
        case "GET":
            return Self.response(200, detail(id, group: group))
        case "PUT":
            guard current.owner == group else { return Self.response(403, ["code": "FORBIDDEN"]) }
            guard json["version"] as? Int == current.version else { return Self.response(409, ["code": "VERSION_CONFLICT"]) }
            collections[id] = (json["name"] as? String ?? current.name, current.owner, current.version + 1,
                               json["content"] as? [String: Any] ?? [:], user)
            return Self.response(200, detail(id, group: group))
        case "DELETE":
            guard current.owner == group else { return Self.response(403, ["code": "FORBIDDEN"]) }
            collections[id] = nil
            return Self.response(204, nil)
        default:
            return Self.response(400, ["code": "INVALID_REQUEST"])
        }
    }

    private func issue(for user: String) -> String {
        counter += 1
        let access = "access-\(user)-\(counter)"
        let refresh = "refresh-\(user)-\(counter)"
        validAccess[access] = user
        validRefresh[refresh] = user
        let group = groupOverride[user] ?? users[user]!.group
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(accessTokenLifetime))
            .replacingOccurrences(of: "Z", with: ".642238Z")
        return Self.response(200, [
            "tokenType": "Bearer", "accessToken": access, "accessTokenExpiresAt": expires,
            "refreshToken": refresh, "refreshTokenExpiresAt": expires,
            "user": ["username": user, "displayName": users[user]!.display], "group": group, "role": group,
            "features": ["app.access"],
        ])
    }

    private func summary(_ id: String, _ c: (name: String, owner: String, version: Int, content: [String: Any], updatedBy: String),
                         group: String) -> [String: Any] {
        ["id": id, "name": c.name, "ownerGroup": c.owner, "version": c.version, "updatedBy": c.updatedBy,
         "updatedAt": "2026-11-10T21:47:48.764341Z", "canUpdate": c.owner == group, "canDelete": c.owner == group]
    }

    private func detail(_ id: String, group: String) -> [String: Any] {
        var item = summary(id, collections[id]!, group: group)
        item["content"] = collections[id]!.content
        return item
    }

    static func response(_ status: Int, _ body: Any?, headers: [String: String] = [:]) -> String {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        var head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        return head + "\r\n" + text
    }
}
