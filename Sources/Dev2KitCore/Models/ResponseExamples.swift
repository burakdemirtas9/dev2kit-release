import Foundation

/// Response örneklerinin kuralları: sınır, anlık görüntü, maskeleme, ad,
/// içe aktarmada seçim. Arayüz (`AppState`) yalnızca bunları çağırır.
///
/// Değişmez kurallar:
/// - İstek başına en çok `limit` örnek. Sınır doluyken ekleme REDDEDİLİR;
///   hiçbir örnek kendiliğinden silinmez ya da üzerine yazılmaz.
/// - Örnek yalnızca gerçek bir HTTP yanıtından alınır; ağ hatası, güvenlik
///   engeli ya da kesilmiş (eksik) yanıt örnek olmaz.
/// - Kimlik bilgisi taşıyan header değerleri ve body'deki kimlik alanları
///   maskelenir: örnekler düz metin workspace dosyasına ve dışa aktarıma
///   giriyor (bkz. `HistoryRedactor`, `CredentialNames`).
public enum ResponseExamples {
    public static let limit = 5

    /// Kenar çubuğunda örnek göstergesi. Dil ne olursa olsun bu metin
    /// (kullanıcı kararı, 2026-10-24).
    public static let badge = "(e.g.)"

    /// Saklanabilecek en büyük body. Örnek koleksiyon dosyasında duruyor ve o
    /// dosya her düzenlemede yeniden yazılıyor; 5 × 50 MB'lık yanıt her tuşta
    /// yüzlerce MB encode demek olurdu. Örnek, belge niteliğinde bir yanıt.
    public static let maxBodyBytes = 1_048_576

    /// Status kodu bilinmeyen (içe aktarılan dosyada yok) örnek.
    public static let unknownStatus = 0

    /// Ekrandaki status: bilinmiyorsa "—".
    public static func statusLabel(_ statusCode: Int) -> String {
        statusCode > 0 ? String(statusCode) : "—"
    }

    /// Örnek adının üst sınırı (istek adlarıyla aynı ölçek).
    public static let maxNameLength = 200

    // MARK: - Anlık görüntü

    public enum CaptureError: Error, LocalizedError, Equatable, Sendable {
        /// Kesilmiş yanıt: body eksik, örnek tutarlı olmaz.
        case truncated
        case tooLarge(bytes: Int)
        /// Token Factory yanıtı token taşır; örnek olarak saklanmaz.
        case tokenFactory

        public var errorDescription: String? {
            switch self {
            case .truncated:
                return L10n.t("example.unavailable.truncated")
            case .tooLarge(let bytes):
                return L10n.t("example.unavailable.tooLarge", TextStats.size(bytes), TextStats.size(ResponseExamples.maxBodyBytes))
            case .tokenFactory:
                return L10n.t("example.unavailable.tokenFactory")
            }
        }
    }

    /// Yanıt örnek olarak kaydedilebilir mi; kaydedilemiyorsa neden.
    public static func unavailableReason(for response: ResponseData, isTokenFactory: Bool = false) -> CaptureError? {
        if isTokenFactory { return .tokenFactory }
        if response.bodyLimitExceeded { return .truncated }
        if response.body.count > maxBodyBytes { return .tooLarge(bytes: response.body.count) }
        return nil
    }

    /// Yanıtın tek seferde alınmış, maskelenmiş anlık görüntüsü. Status,
    /// header'lar, body ve content type AYNI `ResponseData`'dan gelir.
    ///
    /// Body maskelemesi metin boyutuyla büyüyor: çağıran ana thread'de
    /// yapmamalı (`BackgroundWork.run`).
    public static func capture(_ response: ResponseData, name: String, date: Date = Date()) throws -> ResponseExample {
        if let reason = unavailableReason(for: response) { throw reason }
        let headers = response.headers.map { ResponseExample.Header(name: $0.name, value: $0.value) }
        let body = encodedBody(response.body)
        return sanitized(ResponseExample(
            name: name,
            savedAt: date,
            statusCode: response.statusCode,
            headers: headers,
            body: body.text,
            bodyEncoding: body.encoding,
            contentType: contentType(in: headers)
        ))
    }

    /// Kimlik bilgisi maskelenmiş hali. Yakalamada da içe aktarmada da aynı
    /// kural: dışarıdan gelen dosya da workspace'e düz metin token sokmasın.
    public static func sanitized(_ example: ResponseExample) -> ResponseExample {
        var copy = example
        copy.headers = example.headers.map { header in
            guard CredentialNames.isCredentialHeader(header.name), !header.value.isEmpty else { return header }
            return ResponseExample.Header(name: header.name, value: HistoryRedactor.mask)
        }
        if copy.bodyEncoding == .text {
            copy.body = HistoryRedactor.redactStructuredText(example.body)
        }
        copy.name = normalizedName(example.name) ?? defaultName(statusCode: example.statusCode, existing: [])
        return copy
    }

    static func encodedBody(_ data: Data) -> (text: String, encoding: ResponseExample.BodyEncoding) {
        if let text = String(data: data, encoding: .utf8) { return (text, .text) }
        return (data.base64EncodedString(), .base64)
    }

    static func contentType(in headers: [ResponseExample.Header]) -> String? {
        headers.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == "content-type" }?.value
    }

    // MARK: - Ad

    /// Varsayılan ad: "200 OK", "404 Not Found"; aynı ad varsa "(2)", "(3)"…
    public static func defaultName(statusCode: Int, existing: [String]) -> String {
        let base = statusCode <= 0
            ? L10n.t("example.defaultName.noStatus")
            : reasonPhrase(statusCode).map { "\(statusCode) \($0)" } ?? L10n.t("example.defaultName", String(statusCode))
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base) (\($0))" }.first { !taken.contains($0) } ?? base
    }

    /// Boşluklar kırpılır, sınır uygulanır; boş ad geçersiz (`nil`).
    public static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// Standart HTTP gerekçe ifadeleri (RFC 9110). Dil bağımsız, çevrilmez.
    static func reasonPhrase(_ statusCode: Int) -> String? {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return nil
        }
    }

    // MARK: - Ekle, yeniden adlandır, sil

    public enum AddOutcome: Equatable, Sendable {
        case added
        /// Sınır dolu; hiçbir şey değişmedi.
        case limitReached
    }

    public static func canAdd(to request: RequestModel) -> Bool {
        request.examples.count < limit
    }

    /// Örneği sona ekler. Sınır doluysa isteğe dokunmaz.
    public static func add(_ example: ResponseExample, to request: inout RequestModel) -> AddOutcome {
        guard canAdd(to: request) else { return .limitReached }
        var named = example
        named.name = normalizedName(example.name)
            ?? defaultName(statusCode: example.statusCode, existing: request.examples.map(\.name))
        request.examples.append(named)
        return .added
    }

    /// Boş ad reddedilir (`false`); ad değişmez.
    @discardableResult
    public static func rename(_ id: UUID, to name: String, in request: inout RequestModel) -> Bool {
        guard let normalized = normalizedName(name),
              let index = request.examples.firstIndex(where: { $0.id == id }) else { return false }
        request.examples[index].name = normalized
        return true
    }

    @discardableResult
    public static func delete(_ id: UUID, from request: inout RequestModel) -> Bool {
        let before = request.examples.count
        request.examples.removeAll { $0.id == id }
        return request.examples.count != before
    }

    // MARK: - İçe aktarma

    public enum ImportError: Error, LocalizedError, Equatable, Sendable {
        case tooLarge(bytes: Int)
        case invalidBody

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                return L10n.t("example.unavailable.tooLarge", TextStats.size(bytes), TextStats.size(ResponseExamples.maxBodyBytes))
            case .invalidBody:
                return L10n.t("example.import.invalidBody")
            }
        }
    }

    /// Dışarıdan gelen örneği doğrular ve maskeler. Geçersizse gerçek neden.
    ///
    /// Status kodu doğrulanmaz (kullanıcı kararı, 2026-10-24): Postman'de
    /// kodu olmayan örnekler yaygın; olduğu gibi alınır, kod yoksa
    /// `unknownStatus` ve ekranda "—".
    public static func validatedForImport(_ example: ResponseExample) throws -> ResponseExample {
        if example.bodyEncoding == .base64, !example.body.isEmpty, Data(base64Encoded: example.body) == nil {
            throw ImportError.invalidBody
        }
        let bytes = example.bodyEncoding == .text ? example.body.utf8.count : example.bodyData.count
        guard bytes <= maxBodyBytes else { throw ImportError.tooLarge(bytes: bytes) }
        var copy = sanitized(example)
        copy.id = UUID()
        if copy.contentType == nil { copy.contentType = contentType(in: copy.headers) }
        return copy
    }

    /// İsteğin örneklerini doğrular; geçersizler çıkarılır ve her biri için
    /// kullanıcıya gösterilecek not döner. Geçerli olanlar ve istek kalır.
    public static func validatingImported(_ request: RequestModel) -> (request: RequestModel, notes: [String]) {
        var copy = request
        var notes: [String] = []
        copy.examples = request.examples.compactMap { example in
            do {
                return try validatedForImport(example)
            } catch {
                notes.append(L10n.t("example.import.skipped", request.name, example.name, error.localizedDescription))
                return nil
            }
        }
        return (copy, notes)
    }

    /// Sınırı aşan istekler: kullanıcı hangi örneklerin alınacağını seçmeli.
    public static func overflowingRequests(in collection: CollectionModel) -> [RequestModel] {
        collection.requests.filter { $0.examples.count > limit }
    }

    /// Önerilen seçim: dosyadaki sıraya göre ilk `limit` örnek. Yalnızca
    /// başlangıç değeri; kullanıcı onaylamadan uygulanmaz.
    public static func suggestedImportSelection(for collection: CollectionModel) -> [UUID: Set<UUID>] {
        Dictionary(uniqueKeysWithValues: overflowingRequests(in: collection).map { request in
            (request.id, Set(request.examples.prefix(limit).map(\.id)))
        })
    }

    /// Seçim geçerli mi: sınırı aşan her istek için seçim var ve en çok `limit`.
    public static func isValidImportSelection(_ selection: [UUID: Set<UUID>], for collection: CollectionModel) -> Bool {
        overflowingRequests(in: collection).allSatisfy { request in
            guard let picked = selection[request.id] else { return false }
            return picked.count <= limit
        }
    }

    /// Seçimi uygular; sıra dosyadaki gibi kalır. Seçim geçersizse `nil`:
    /// fazlalık sessizce atılmaz, çağıran kullanıcıya sormalı.
    public static func applyingImportSelection(_ selection: [UUID: Set<UUID>], to collection: CollectionModel) -> CollectionModel? {
        guard isValidImportSelection(selection, for: collection) else { return nil }
        var copy = collection
        for index in copy.requests.indices where copy.requests[index].examples.count > limit {
            let picked = selection[copy.requests[index].id] ?? []
            copy.requests[index].examples.removeAll { !picked.contains($0.id) }
        }
        return copy
    }
}
