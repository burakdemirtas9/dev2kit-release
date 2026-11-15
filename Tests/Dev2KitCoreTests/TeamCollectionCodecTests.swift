import XCTest
@testable import Dev2KitCore

/// Servis içeriği ↔ collection; kaydetmede gizli bilgi ayıklama; izin kuralı.
final class TeamCollectionCodecTests: XCTestCase {
    func testTolerantDecodeOfTheGuideExample() throws {
        let content = Data(#"{"requests": [{"name": "charge", "method": "POST"}, {"method": "nope"}, 5]}"#.utf8)
        let decoded = try TeamCollectionCodec.decode(content, remoteID: "r1", name: "Payments API")
        XCTAssertEqual(decoded.collection.name, "Payments API")
        XCTAssertEqual(decoded.collection.requests.map(\.name), ["charge", "Request 2"])
        XCTAssertEqual(decoded.collection.requests.map(\.method), [.post, .get])
        XCTAssertEqual(decoded.skippedRequests, 1)
        let again = try TeamCollectionCodec.decode(content, remoteID: "r1", name: "Payments API")
        XCTAssertEqual(again.collection.id, decoded.collection.id, "kimlikler kararlı: sekmeler korunur")
        XCTAssertEqual(again.collection.requests.map(\.id), decoded.collection.requests.map(\.id))
        XCTAssertNotEqual(try TeamCollectionCodec.decode(content, remoteID: "r2", name: "x").collection.id, decoded.collection.id)
    }

    func testRoundTripKeepsRequestIDsAndDropsExamples() throws {
        var request = RequestModel(name: "pay", method: .post, url: "{{baseUrl}}/pay")
        request.headers = [KeyValueEntry(key: "Authorization", value: "Bearer {{token}}")]
        request.examples = [ResponseExample(name: "ok", statusCode: 200, body: "müşteri verisi")]
        let collection = CollectionModel(name: "Pay", requests: [request])
        let content = try TeamCollectionCodec.encode(collection)
        XCTAssertFalse(String(decoding: content, as: UTF8.self).contains("müşteri verisi"), "örnekler gönderilmez")
        let decoded = try TeamCollectionCodec.decode(content, remoteID: "r1", name: "Pay").collection
        XCTAssertEqual(decoded.requests.first?.id, request.id)
        XCTAssertEqual(decoded.requests.first?.url, "{{baseUrl}}/pay")
        XCTAssertTrue(decoded.requests.first?.examples.isEmpty == true)
    }

    func testPlaintextCredentialsBlockSaving() {
        var request = RequestModel(name: "pay", method: .get, url: "https://a.test")
        request.headers = [KeyValueEntry(key: "Authorization", value: "Bearer eyJhbGciOi.gerçek.token")]
        XCTAssertThrowsError(try TeamCollectionCodec.encode(CollectionModel(name: "x", requests: [request]))) { error in
            guard case TeamError.plaintextCredentials(let places) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(places.first?.contains("pay") == true)
        }
    }

    // MARK: Paylaşım denetimi (kapalı satırlar, gövde alanları)

    private func places(_ request: RequestModel) -> [String] {
        do {
            _ = try TeamCollectionCodec.encode(CollectionModel(name: "x", requests: [request]))
            return []
        } catch TeamError.plaintextCredentials(let places) {
            return places
        } catch {
            XCTFail("\(error)")
            return []
        }
    }

    /// Login isteğinin ham JSON gövdesindeki parola kuruma gitmez.
    func testBodyPasswordBlocksSaving() {
        var request = RequestModel(name: "login", method: .post, url: "https://a.test/login")
        request.body = .raw(content: #"{"username": "u", "password": "Pa55w0rd!"}"#, contentType: "application/json")
        XCTAssertTrue(places(request).first?.contains("password") == true)

        request.body = .raw(content: #"{"pwd": 123456}"#, contentType: "application/json")
        XCTAssertFalse(places(request).isEmpty, "sayı değerli parola da")

        request.body = .raw(content: #"{"client_secret": "0123456789abcdef0123"}"#, contentType: "application/json")
        XCTAssertFalse(places(request).isEmpty, "opak değerli secret alanı")
    }

    /// Kapalı satır gönderilmez ama belgeye yazılır: o da denetlenir.
    func testDisabledRowsBlockSaving() {
        var request = RequestModel(name: "pay", method: .post, url: "https://a.test")
        request.headers = [KeyValueEntry(key: "Authorization", value: "Bearer abcdefghijklmnopqrstuvwxyz012345", enabled: false)]
        XCTAssertTrue(places(request).first?.contains("Authorization") == true)

        request.headers = []
        request.body = .formURLEncoded(fields: [KeyValueEntry(key: "password", value: "Pa55w0rd!", enabled: false)])
        XCTAssertFalse(places(request).isEmpty)

        request.body = .none
        request.queryParams = [KeyValueEntry(key: "access_token", value: "0123456789abcdef0123", enabled: false)]
        XCTAssertFalse(places(request).isEmpty)
    }

    /// Engel fazlasını tutmaz: değişken, boş değer ve sıradan alanlar geçer.
    func testSharingCheckAllowsVariablesAndOrdinaryFields() {
        var request = RequestModel(name: "ok", method: .post, url: "{{baseUrl}}/login")
        request.headers = [KeyValueEntry(key: "Authorization", value: "Bearer {{token}}", enabled: false)]
        request.body = .raw(content: """
        {"username": "u", "password": "{{password}}", "secret": "", "tokenType": "Bearer",
         "key": "ad", "sessionId": "abc", "passenger": "Ali", "pin": 1234}
        """, contentType: "application/json")
        XCTAssertEqual(places(request), [])
    }

    /// İçe aktarma incelemesi eski kuralla kalır (orada bulgu yalnızca uyarıdır).
    func testImportReviewRuleIsUnchanged() {
        var request = RequestModel(name: "login", method: .post, url: "https://a.test/login")
        request.headers = [KeyValueEntry(key: "Authorization", value: "Bearer abcdefghijklmnopqrstuvwxyz012345", enabled: false)]
        request.body = .raw(content: #"{"password": "Pa55w0rd!"}"#, contentType: "application/json")
        XCTAssertEqual(ImportReviewer.plaintextCredentials(in: request), [])
        XCTAssertFalse(ImportReviewer.plaintextCredentials(in: request, forSharing: true).isEmpty)
    }

    // MARK: Eksik ya da tanınmayan içerik

    /// Tanınmayan belge boş collection olarak açılmaz (kayıt onu ezerdi).
    func testUnrecognizedContentIsNotOpenedAsEmpty() throws {
        for text in [#"{"info": {"name": "p"}, "item": []}"#, #"{"requests": "yok"}"#, #"{"collection": {"name": "x"}}"#] {
            XCTAssertThrowsError(try TeamCollectionCodec.decode(Data(text.utf8), remoteID: "r1", name: "x"), text) {
                XCTAssertEqual($0 as? TeamError, .unsupportedContent)
            }
        }
        XCTAssertTrue(try TeamCollectionCodec.decode(Data("{}".utf8), remoteID: "r1", name: "x").collection.requests.isEmpty,
                      "boş belge yeni collection'dır")
        XCTAssertTrue(try TeamCollectionCodec.decode(Data(#"{"requests": []}"#.utf8), remoteID: "r1", name: "x").collection.requests.isEmpty)
    }

    /// Okunamayan istek varsa yerel hal eksiktir: düzenlenemez, yani kaydedilemez.
    func testSkippedRequestsMakeTheCollectionReadOnly() throws {
        let summary = TeamCollectionSummary(id: "r1", name: "T", ownerGroup: "g", version: 2, canUpdate: true, canDelete: true)
        let partial = TeamCollectionDetail(summary: summary, content: Data(#"{"requests": [{"name": "a"}, 5]}"#.utf8))
        let result = try TeamSync.apply(partial, to: [], catalog: TeamCatalog())
        let id = result.collections[0].id
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.catalog.entries[id]?.skippedRequests, 1)
        XCTAssertFalse(result.catalog.canEdit(id), "eksik içerik düzenlenmez")

        let whole = TeamCollectionDetail(summary: summary, content: Data(#"{"requests": [{"name": "a"}]}"#.utf8))
        let fixed = try TeamSync.apply(whole, to: result.collections, catalog: result.catalog)
        XCTAssertTrue(fixed.catalog.canEdit(id), "eksiksiz okununca yeniden düzenlenir")
    }

    /// `skippedRequests` alanı olmayan (önceki) önbellek kaydı da açılır.
    func testInfoDecodesWithoutSkippedField() throws {
        let summary = TeamCollectionSummary(id: "r1", name: "T", ownerGroup: "g", version: 0, canUpdate: true, canDelete: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TeamCollectionInfo(summary: summary, isLoaded: true, isDirty: true))) as? [String: Any])
        object["skippedRequests"] = nil
        let info = try JSONDecoder().decode(TeamCollectionInfo.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(info, TeamCollectionInfo(summary: summary, isLoaded: true, isDirty: true))
    }

    /// İçeriksiz yanıt boş collection sayılmaz: okumada hata, yazmada kaydedilen belge.
    func testResponseWithoutContentIsNeverTreatedAsEmpty() throws {
        let response = Data(#"{"id": "r1", "name": "T", "ownerGroup": "g", "version": 4, "canUpdate": true, "canDelete": true}"#.utf8)
        XCTAssertThrowsError(try TeamDataClient.detail(from: response)) {
            XCTAssertEqual($0 as? TeamError, .invalidResponse)
        }
        let sent = Data(#"{"requests": [{"name": "a"}]}"#.utf8)
        let saved = try TeamDataClient.detail(from: response, sentContent: sent)
        XCTAssertEqual(saved.content, sent)
        XCTAssertEqual(saved.summary.version, 4)

        let withContent = Data(#"{"id": "r1", "name": "T", "ownerGroup": "g", "version": 4, "canUpdate": true, "canDelete": true, "content": {"requests": []}}"#.utf8)
        XCTAssertNotEqual(try TeamDataClient.detail(from: withContent, sentContent: sent).content, sent, "sunucunun gönderdiği içerik önceliklidir")
    }

    func testCollisionsAreRenamedStably() {
        let shared = UUID()
        let collection = CollectionModel(name: "x", requests: [RequestModel(id: shared, name: "a", method: .get, url: "")])
        let resolved = TeamCollectionCodec.resolvingCollisions(collection, used: [shared], remoteID: "r1")
        XCTAssertNotEqual(resolved.requests[0].id, shared)
        XCTAssertEqual(resolved.requests[0].id, TeamCollectionCodec.resolvingCollisions(collection, used: [shared], remoteID: "r1").requests[0].id)
        XCTAssertEqual(TeamCollectionCodec.resolvingCollisions(collection, used: [], remoteID: "r1").requests[0].id, shared)
    }

    func testCatalogPermissionsAndPersistenceExclusion() {
        let team = CollectionModel(name: "T", requests: [RequestModel(name: "a", method: .get, url: "")])
        let mine = CollectionModel(name: "M")
        let summary = TeamCollectionSummary(id: "r1", name: "T", ownerGroup: "g", version: 0, canUpdate: true, canDelete: false)
        var catalog = TeamCatalog(entries: [team.id: TeamCollectionInfo(summary: summary)])
        XCTAssertFalse(catalog.canEdit(team.id), "içerik çekilmeden düzenlenmez")
        catalog.entries[team.id]?.isLoaded = true
        XCTAssertTrue(catalog.canEdit(team.id))
        XCTAssertFalse(catalog.canDelete(team.id))
        XCTAssertTrue(catalog.canEdit(mine.id), "kendi collection'ı serbest")

        var workspace = WorkspaceModel(collections: [team, mine])
        workspace.sentBaselines[team.requests[0].id.uuidString] = team.requests[0]
        let saved = workspace.excludingCollections([team.id])
        XCTAssertEqual(saved.collections.map(\.id), [mine.id])
        XCTAssertTrue(saved.sentBaselines.isEmpty, "kurum isteklerinin son gönderilenleri de yazılmaz")
    }

    // MARK: Sınırlar (bulgu 10)

    private func decode(_ requests: [[String: Any]]) throws -> TeamCollectionCodec.Decoded {
        let data = try JSONSerialization.data(withJSONObject: ["requests": requests])
        return try TeamCollectionCodec.decode(data, remoteID: "r1", name: "T")
    }

    /// Tek satırlık alanda megabaytlık değer, binlerce satır, aşırı derinlik:
    /// istek atlanır (collection salt okunur açılır), diğerleri açılır.
    func testRequestsOverTheLimitsAreSkipped() throws {
        let tooLong = String(repeating: "a", count: TeamCollectionCodec.Limits.maxFieldCharacters + 1)
        let manyRows = (0...TeamCollectionCodec.Limits.maxRows).map { ["key": "k\($0)", "value": "v"] }
        var deep: Any = "x"
        for _ in 0...TeamCollectionCodec.Limits.maxDepth { deep = ["n": deep] }
        let decoded = try decode([
            ["name": "ok", "method": "GET", "url": "https://a.test"],
            ["name": "header", "headers": [["key": "X", "value": tooLong]]],
            ["name": "rows", "headers": manyRows],
            ["name": "url", "url": tooLong],
            ["name": "deep", "extra": deep],
            ["name": "form", "body": ["formURLEncoded": ["fields": [["key": "a", "value": tooLong]]]]],
        ])
        XCTAssertEqual(decoded.collection.requests.map(\.name), ["ok"])
        XCTAssertEqual(decoded.skippedRequests, 5)
    }

    /// Ham gövde kod editöründe açılır: alan sınırına değil editör sınırına tabi.
    func testRawBodyUsesTheEditorLimit() throws {
        let large = String(repeating: "b", count: TeamCollectionCodec.Limits.maxFieldCharacters * 10)
        let decoded = try decode([["name": "big body", "body": ["raw": ["content": large, "contentType": "text/plain"]]]])
        XCTAssertEqual(decoded.collection.requests.count, 1)
        XCTAssertEqual(decoded.skippedRequests, 0)
        XCTAssertFalse(TeamCollectionCodec.exceedsLimits(["body": ["raw": ["content": large]]]))
        let tooLarge = String(repeating: "b", count: TeamCollectionCodec.Limits.maxBodyBytes + 1)
        XCTAssertTrue(TeamCollectionCodec.exceedsLimits(["body": ["raw": ["content": tooLarge]]]))
    }

    /// İstek sayısı sınırı: fazlası atlanıp sayılır.
    func testRequestCountIsCapped() throws {
        let count = TeamCollectionCodec.Limits.maxRequests + 3
        let decoded = try decode((0..<count).map { ["name": "r\($0)"] })
        XCTAssertEqual(decoded.collection.requests.count, TeamCollectionCodec.Limits.maxRequests)
        XCTAssertEqual(decoded.skippedRequests, 3)
    }

    /// Örnekler sınıra sayılmaz (zaten alınmazlar).
    func testExamplesDoNotCountTowardsTheLimits() throws {
        let tooLong = String(repeating: "a", count: TeamCollectionCodec.Limits.maxFieldCharacters + 1)
        let decoded = try decode([["name": "a", "examples": [["name": tooLong]]]])
        XCTAssertEqual(decoded.collection.requests.count, 1)
    }

    // MARK: Kayıt sınırı (2026-11-15)

    /// Sunucuya giden belge sıkışık biçimde ölçülür: girintili hali sınırı
    /// aşsa da sıkışığı sığıyorsa gönderilir; sığmıyorsa hiç gönderilmez.
    func testSaveLimitIsMeasuredOnTheCompactDocument() throws {
        let limit = TeamCollectionCodec.maxSaveBytes
        let body = String(repeating: "x", count: limit - 20_000)
        var request = RequestModel(name: "big")
        request.body = .raw(content: body, contentType: "text/plain")
        let fits = try TeamCollectionCodec.encode(CollectionModel(name: "C", requests: [request]))
        XCTAssertNoThrow(try TeamDataClient.body(name: "C", content: fits, version: 0))

        request.body = .raw(content: body + String(repeating: "x", count: 40_000), contentType: "text/plain")
        let tooLarge = try TeamCollectionCodec.encode(CollectionModel(name: "C", requests: [request]))
        XCTAssertThrowsError(try TeamDataClient.body(name: "C", content: tooLarge, version: 0)) {
            XCTAssertEqual($0 as? TeamError, .contentTooLarge)
        }
        XCTAssertTrue(TeamError.contentTooLarge.localizedDescription.contains(TextStats.size(limit)),
                      "mesaj sınırı söyler")
    }

    /// Okuma sınırı ayrı: eski 5 MB sınırıyla kaydedilmiş belgeler açılmaya devam eder.
    func testDocumentsLargerThanTheSaveLimitStillOpen() throws {
        let body = String(repeating: "y", count: TeamCollectionCodec.maxSaveBytes * 2)
        let data = try JSONSerialization.data(withJSONObject: ["requests": [["name": "a", "body": ["raw": ["content": body, "contentType": "text/plain"]]]]])
        let decoded = try TeamCollectionCodec.decode(data, remoteID: "r1", name: "T")
        XCTAssertEqual(decoded.collection.requests.count, 1)
    }
}
