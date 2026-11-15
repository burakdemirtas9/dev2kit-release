import Foundation

/// dev2kit-data istemcisi (rehber §4–§5). Her çağrı `TeamSession.send`
/// üzerinden (Bearer, 401'de bir kez refresh). 403, 404 ve 409 otomatik
/// tekrarlanmaz; izin ipuçları (`canUpdate`…) yalnızca arayüz içindir, sunucu
/// her çağrıyı yeniden yetkilendirir.
public struct TeamDataClient: Sendable {
    public let session: TeamSession

    public init(session: TeamSession) {
        self.session = session
    }

    private var base: URL { session.config.dataBaseURL }

    public func me() async throws -> TeamMe {
        let data = try await call("GET", "me")
        guard let me = try? JSONDecoder().decode(TeamMe.self, from: data) else { throw TeamError.invalidResponse }
        return me
    }

    public func list() async throws -> [TeamCollectionSummary] {
        let data = try await call("GET", "collections")
        guard let items = try? JSONDecoder().decode([TeamCollectionSummary].self, from: data) else { throw TeamError.invalidResponse }
        return items
    }

    public func fetch(id: String) async throws -> TeamCollectionDetail {
        try Self.requireValidID(id)
        return try Self.detail(from: await call("GET", "collections/\(id)"))
    }

    public func create(name: String, content: Data) async throws -> TeamCollectionDetail {
        let body = try Self.body(name: name, content: content, version: nil)
        return try Self.detail(from: await call("POST", "collections", body: body), sentContent: content)
    }

    /// Belge bütün olarak gönderilir; `version` uygulamanın en son okuduğu değer.
    public func update(id: String, name: String, content: Data, version: Int) async throws -> TeamCollectionDetail {
        try Self.requireValidID(id)
        let body = try Self.body(name: name, content: content, version: version)
        return try Self.detail(from: await call("PUT", "collections/\(id)", body: body), sentContent: content)
    }

    public func delete(id: String) async throws {
        try Self.requireValidID(id)
        _ = try await call("DELETE", "collections/\(id)")
    }

    // MARK: Kurallar

    /// Sunucunun kuralı (`^[\\p{L}\\p{N}][\\p{L}\\p{N} ._()/-]{0,119}$`): harf ya da
    /// rakamla başlar; harf (Türkçe dahil), rakam, boşluk ve `. _ ( ) / -`; en çok 120.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber, name.count <= 120 else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || " ._()/-".contains($0) }
    }

    /// Yanıttan gelen kimlik adrese eklenmeden önce: `../`, `?` taşımasın.
    static func requireValidID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 128, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw TeamError.invalidResponse
        }
    }

    static func body(name: String, content: Data, version: Int?) throws -> Data {
        guard isValidName(name) else { throw TeamError.invalidName }
        guard content.count <= TeamCollectionCodec.maxContentBytes,
              let object = try? JSONSerialization.jsonObject(with: content), object is [String: Any] else {
            throw content.count > TeamCollectionCodec.maxContentBytes ? TeamError.contentTooLarge : TeamError.invalidRequest
        }
        // Sunucunun ölçtüğü biçim: sıkışık JSON. Sınırı aşan belge hiç gönderilmez.
        guard let compact = try? JSONSerialization.data(withJSONObject: object),
              compact.count <= TeamCollectionCodec.maxSaveBytes else {
            throw TeamError.contentTooLarge
        }
        var payload: [String: Any] = ["name": name, "content": object]
        if let version { payload["version"] = version }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Yanıttaki özet + içerik. İçerik yoksa ya da nesne değilse boş collection
    /// SAYILMAZ: yerel hal boşalır, sonraki kayıt sunucudaki belgeyi ezerdi.
    /// - Okuma (`sentContent == nil`): yanıt geçersiz.
    /// - Yazma: sunucu içeriği geri göndermediyse az önce kaydedilen belge geçerlidir.
    static func detail(from data: Data, sentContent: Data? = nil) throws -> TeamCollectionDetail {
        guard let summary = try? JSONDecoder().decode(TeamCollectionSummary.self, from: data),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TeamError.invalidResponse
        }
        let received = (root["content"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        guard let content = received ?? sentContent else { throw TeamError.invalidResponse }
        return TeamCollectionDetail(summary: summary, content: content)
    }

    // MARK: Çağrı

    private func call(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.send(request)
        switch response.statusCode {
        case 200, 201, 204: return data
        case 401: throw TeamError.sessionExpired
        case 403: throw TeamError.forbidden
        case 404: throw TeamError.notFound
        case 409: throw Self.errorCode(data) == "NAME_TAKEN" ? TeamError.nameTaken : TeamError.versionConflict
        case 413: throw TeamError.contentTooLarge
        case 400: throw TeamError.invalidRequest
        default: throw TeamError.http(response.statusCode)
        }
    }

    static func errorCode(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
    }
}
