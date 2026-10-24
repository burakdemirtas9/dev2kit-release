import XCTest
@testable import Dev2KitCore

/// Response örneklerinin kuralları: anlık görüntü, maskeleme, 5 sınırı,
/// ad, kalıcılık biçimi ve içe aktarmada seçim.
final class ResponseExamplesTests: XCTestCase {
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    private func response(
        status: Int = 200,
        headers: [(name: String, value: String)] = [("Content-Type", "application/json")],
        body: String = #"{"id": 1}"#,
        truncated: Bool = false
    ) -> ResponseData {
        ResponseData(statusCode: status, headers: headers, body: Data(body.utf8), duration: 0.2,
                     finalURL: nil, bodyLimitExceeded: truncated)
    }

    private func example(_ name: String, status: Int = 200) -> ResponseExample {
        ResponseExample(name: name, statusCode: status, body: "{}")
    }

    // MARK: - Anlık görüntü

    func testCaptureKeepsStatusHeadersBodyAndContentTypeTogether() throws {
        let captured = try ResponseExamples.capture(
            response(status: 201, headers: [("Content-Type", "application/json; charset=utf-8"), ("X-Trace", "abc")],
                     body: #"{"name": "Ada"}"#),
            name: "Oluşturuldu"
        )
        XCTAssertEqual(captured.statusCode, 201)
        XCTAssertEqual(captured.contentType, "application/json; charset=utf-8")
        XCTAssertEqual(captured.headers.map(\.name), ["Content-Type", "X-Trace"])
        XCTAssertEqual(captured.body, #"{"name": "Ada"}"#)
        XCTAssertEqual(captured.bodyEncoding, .text)
        XCTAssertEqual(captured.name, "Oluşturuldu")
        // Gösterim için geri çevrilen yanıt aynı veriyi taşır.
        XCTAssertEqual(captured.responseData.statusCode, 201)
        XCTAssertEqual(captured.responseData.bodyText, #"{"name": "Ada"}"#)
    }

    func testCaptureMasksCredentialHeadersAndBodyFields() throws {
        let captured = try ResponseExamples.capture(
            response(headers: [("Set-Cookie", "SESSION=abc123"), ("Authorization", "Bearer eyJ"), ("Content-Type", "application/json")],
                     body: #"{"access_token": "eyJhbGciOi", "user": "ada"}"#),
            name: "x"
        )
        XCTAssertEqual(captured.headers.first { $0.name == "Set-Cookie" }?.value, HistoryRedactor.mask)
        XCTAssertEqual(captured.headers.first { $0.name == "Authorization" }?.value, HistoryRedactor.mask)
        XCTAssertFalse(captured.body.contains("eyJhbGciOi"), "body'deki token düz metin kalmamalı")
        XCTAssertTrue(captured.body.contains(#""user": "ada""#), "kimlik dışı alanlar korunur")
    }

    func testBinaryBodyRoundtripsAsBase64() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0x00, 0xFE])
        let data = ResponseData(statusCode: 200, headers: [("Content-Type", "image/png")], body: bytes, duration: 0, finalURL: nil)
        let captured = try ResponseExamples.capture(data, name: "png")
        XCTAssertEqual(captured.bodyEncoding, .base64)
        XCTAssertEqual(captured.bodyData, bytes)
    }

    func testEmptyBodyIsAValidExample() throws {
        let captured = try ResponseExamples.capture(response(status: 204, headers: [], body: ""), name: "")
        XCTAssertEqual(captured.body, "")
        XCTAssertNil(captured.contentType)
        XCTAssertEqual(captured.name, "204 No Content", "boş ad varsayılana düşer")
    }

    func testTruncatedTooLargeAndTokenFactoryResponsesAreNotCaptured() {
        XCTAssertThrowsError(try ResponseExamples.capture(response(truncated: true), name: "x")) {
            XCTAssertEqual($0 as? ResponseExamples.CaptureError, .truncated)
        }
        let big = String(repeating: "a", count: ResponseExamples.maxBodyBytes + 1)
        XCTAssertEqual(ResponseExamples.unavailableReason(for: response(body: big)), .tooLarge(bytes: big.utf8.count))
        XCTAssertEqual(ResponseExamples.unavailableReason(for: response(), isTokenFactory: true), .tokenFactory)
        XCTAssertNil(ResponseExamples.unavailableReason(for: response()))
    }

    // MARK: - Sınır

    func testZeroToFiveAreAddedAndSixthIsRefusedWithoutChange() {
        var request = RequestModel(name: "r")
        for index in 0..<ResponseExamples.limit {
            XCTAssertTrue(ResponseExamples.canAdd(to: request))
            XCTAssertEqual(ResponseExamples.add(example("e\(index)"), to: &request), .added)
        }
        XCTAssertEqual(request.examples.count, 5)
        let before = request.examples
        XCTAssertFalse(ResponseExamples.canAdd(to: request))
        XCTAssertEqual(ResponseExamples.add(example("altıncı"), to: &request), .limitReached)
        XCTAssertEqual(request.examples, before, "hiçbir örnek silinmez ya da üzerine yazılmaz")
    }

    func testDeleteThenAddAgain() {
        var request = RequestModel(name: "r")
        (0..<5).forEach { _ = ResponseExamples.add(example("e\($0)"), to: &request) }
        let removed = request.examples[2].id
        XCTAssertTrue(ResponseExamples.delete(removed, from: &request))
        XCTAssertFalse(ResponseExamples.delete(removed, from: &request), "ikinci silme bir şey yapmaz")
        XCTAssertEqual(ResponseExamples.add(example("yeni"), to: &request), .added)
        XCTAssertEqual(request.examples.map(\.name), ["e0", "e1", "e3", "e4", "yeni"])
    }

    func testRenameTrimsAndRejectsEmpty() {
        var request = RequestModel(name: "r")
        _ = ResponseExamples.add(example("eski"), to: &request)
        let id = request.examples[0].id
        XCTAssertTrue(ResponseExamples.rename(id, to: "  yeni ad \n", in: &request))
        XCTAssertEqual(request.examples[0].name, "yeni ad")
        XCTAssertFalse(ResponseExamples.rename(id, to: "   ", in: &request))
        XCTAssertEqual(request.examples[0].name, "yeni ad")
        XCTAssertFalse(ResponseExamples.rename(UUID(), to: "x", in: &request))
    }

    func testDefaultNameIsUniqueAndUsesReasonPhrase() {
        XCTAssertEqual(ResponseExamples.defaultName(statusCode: 404, existing: []), "404 Not Found")
        XCTAssertEqual(ResponseExamples.defaultName(statusCode: 200, existing: ["200 OK"]), "200 OK (2)")
        XCTAssertEqual(ResponseExamples.defaultName(statusCode: 200, existing: ["200 OK", "200 OK (2)"]), "200 OK (3)")
        XCTAssertEqual(ResponseExamples.defaultName(statusCode: 299, existing: []), "299 response")
    }

    // MARK: - Kalıcı biçim

    func testRequestWithoutExamplesIsEncodedWithoutTheField() throws {
        let json = String(decoding: try JSONEncoder().encode(RequestModel(name: "r")), as: UTF8.self)
        XCTAssertFalse(json.contains("examples"), "mevcut dosyalar bu özellik yüzünden değişmesin")
    }

    func testLegacyRequestDecodesWithNoExamples() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"eski","method":"GET","url":"https://a.b"}"#
        let request = try JSONDecoder().decode(RequestModel.self, from: Data(legacy.utf8))
        XCTAssertEqual(request.examples, [])
    }

    func testExamplesRoundtripAndMalformedEntryIsSkipped() throws {
        var request = RequestModel(name: "r")
        _ = ResponseExamples.add(example("iyi"), to: &request)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(RequestModel.self, from: data).examples, request.examples)

        // Elle bozulmuş tek örnek: istek ve diğer örnekler okunur, sayı raporlanır.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var examples = try XCTUnwrap(object["examples"] as? [Any])
        examples.insert(["name": "bozuk"], at: 0)
        examples.append("metin")
        object["examples"] = examples
        let broken = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        let report = ExampleDecodeReport()
        decoder.userInfo[ExampleDecodeReport.key] = report
        let decoded = try decoder.decode(RequestModel.self, from: broken)
        XCTAssertEqual(decoded.examples.map(\.name), ["iyi"])
        XCTAssertEqual(report.unreadable.first?.count, 2)
        XCTAssertEqual(report.unreadable.first?.requestName, "r")
    }

    func testExamplesDoNotAffectFunctionalEquality() {
        var request = RequestModel(name: "r", url: "https://a.b")
        let baseline = request
        _ = ResponseExamples.add(example("e"), to: &request)
        XCTAssertTrue(request.isFunctionallyEqual(to: baseline), "örnek kaydetmek isteği 'değişti' yapmaz")
        XCTAssertEqual(request.revertingFunctionalFields(to: baseline).examples.count, 1, "geri dönüş örnekleri silmez")
        XCTAssertEqual(request.withoutExamples.examples, [])
    }

    func testRegeneratingExampleIDs() {
        var request = RequestModel(name: "r")
        _ = ResponseExamples.add(example("e"), to: &request)
        let copy = request.regeneratingExampleIDs()
        XCTAssertNotEqual(copy.examples[0].id, request.examples[0].id)
        XCTAssertEqual(copy.examples[0].name, "e")
    }

    // MARK: - İçe aktarma

    func testImportDoesNotValidateStatusButReportsRealBodyProblems() throws {
        // Status doğrulanmaz (kullanıcı kararı): olağandışı ya da eksik kod alınır.
        XCTAssertEqual(try ResponseExamples.validatedForImport(ResponseExample(name: "x", statusCode: 42)).statusCode, 42)
        let unknown = try ResponseExamples.validatedForImport(ResponseExample(name: "", statusCode: ResponseExamples.unknownStatus))
        XCTAssertEqual(unknown.name, "Örnek")
        XCTAssertEqual(ResponseExamples.statusLabel(unknown.statusCode), "—")
        let noStatus = #"{"id":"\#(UUID().uuidString)","name":"kodsuz"}"#
        XCTAssertEqual(try JSONDecoder().decode(ResponseExample.self, from: Data(noStatus.utf8)).statusCode, ResponseExamples.unknownStatus)

        XCTAssertThrowsError(try ResponseExamples.validatedForImport(
            ResponseExample(name: "x", statusCode: 200, body: "%%%", bodyEncoding: .base64))) {
            XCTAssertEqual($0 as? ResponseExamples.ImportError, .invalidBody)
        }
        var request = RequestModel(name: "Kullanıcı")
        request.examples = [ResponseExample(name: "iyi", statusCode: 200),
                            ResponseExample(name: "kötü", statusCode: 200, body: "%%%", bodyEncoding: .base64)]
        let checked = ResponseExamples.validatingImported(request)
        XCTAssertEqual(checked.request.examples.map(\.name), ["iyi"])
        XCTAssertEqual(checked.notes.count, 1)
        XCTAssertTrue(checked.notes[0].contains("kötü") && checked.notes[0].contains("base64"), checked.notes[0])
    }

    func testImportSelectionNeverTrimsSilently() {
        var request = RequestModel(name: "çok")
        request.examples = (0..<7).map { example("e\($0)") }
        let small = RequestModel(name: "az", examples: [example("tek")])
        let collection = CollectionModel(name: "c", requests: [request, small])

        XCTAssertEqual(ResponseExamples.overflowingRequests(in: collection).map(\.id), [request.id])
        XCTAssertNil(ResponseExamples.applyingImportSelection([:], to: collection), "seçim yoksa uygulanmaz")
        let tooMany = [request.id: Set(request.examples.prefix(6).map(\.id))]
        XCTAssertNil(ResponseExamples.applyingImportSelection(tooMany, to: collection))

        let suggested = ResponseExamples.suggestedImportSelection(for: collection)
        XCTAssertEqual(suggested[request.id]?.count, 5)
        let picked = [request.id: Set([request.examples[6].id, request.examples[1].id])]
        let applied = ResponseExamples.applyingImportSelection(picked, to: collection)
        XCTAssertEqual(applied?.requests[0].examples.map(\.name), ["e1", "e6"], "dosyadaki sıra korunur")
        XCTAssertEqual(applied?.requests[1].examples.map(\.name), ["tek"], "sınır içindeki istek değişmez")
    }

    func testReviewWithOverflowIsNotCleanAndSelectionKeepsIdentity() {
        var request = RequestModel(name: "çok", url: "https://api.example.com")
        request.examples = (0..<6).map { example("e\($0)") }
        let review = ImportReviewer.review(
            collection: CollectionModel(name: "c", requests: [request]),
            notes: [],
            context: ImportReviewer.Context(policy: .notConfigured, vaultSecretNames: [])
        )
        XCTAssertFalse(review.isClean, "fazla örnek inceleme ekranını açtırmalı")
        XCTAssertEqual(review.requestsOverExampleLimit.count, 1)
        XCTAssertNil(review.applyingExampleSelection([:]))
        let resolved = review.applyingExampleSelection([request.id: Set(request.examples.prefix(5).map(\.id))])
        XCTAssertEqual(resolved?.id, review.id)
        XCTAssertEqual(resolved?.importableCollection.requests[0].examples.count, 5)
        XCTAssertEqual(resolved?.requestsOverExampleLimit.count, 0)
    }

    // MARK: - Kenar çubuğu satırları

    func testTreeRowsPlaceExamplesUnderTheirRequest() {
        let a = RequestModel(name: "a", examples: [example("a1"), example("a2")])
        let b = RequestModel(name: "b")
        let rows = RequestTreeRows.rows(for: [a, b])
        XCTAssertEqual(rows.map(\.id), [a.id, a.examples[0].id, a.examples[1].id, b.id])
        XCTAssertEqual(RequestTreeRows.exampleOwners(in: [a, b])[a.examples[1].id], a.id)
    }

    func testMoveIndicesAreTranslatedToRequestIndices() throws {
        let a = RequestModel(name: "a", examples: [example("a1"), example("a2")])
        let b = RequestModel(name: "b")
        let c = RequestModel(name: "c", examples: [example("c1")])
        let rows = RequestTreeRows.rows(for: [a, b, c])   // a a1 a2 b c c1

        // b (satır 3) en başa.
        var move = try XCTUnwrap(RequestTreeRows.requestMove(source: [3], destination: 0, in: rows))
        XCTAssertEqual(move.source, [1]); XCTAssertEqual(move.destination, 0)
        var requests = [a, b, c]
        requests.move(fromOffsets: move.source, toOffset: move.destination)
        XCTAssertEqual(requests.map(\.name), ["b", "a", "c"])

        // a (satır 0) en sona.
        move = try XCTUnwrap(RequestTreeRows.requestMove(source: [0], destination: rows.count, in: rows))
        XCTAssertEqual(move.source, [0]); XCTAssertEqual(move.destination, 3)

        // Hedef a'nın örnekleri arasında: b, a'nın ardına (yerinde kalır).
        move = try XCTUnwrap(RequestTreeRows.requestMove(source: [3], destination: 2, in: rows))
        XCTAssertEqual(move.destination, 1)

        XCTAssertNil(RequestTreeRows.requestMove(source: [1], destination: 0, in: rows), "örnek satırı taşınmaz")
    }

    // MARK: - Diskte kalıcılık

    func testExamplesSurviveStoreReopen() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dev2kit-examples-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = RequestModel(name: "r")
        _ = ResponseExamples.add(try ResponseExamples.capture(response(), name: "kayıt"), to: &request)
        let workspace = WorkspaceModel(collections: [CollectionModel(name: "c", requests: [request])])

        try WorkspaceStore(directory: directory).save(workspace)
        let reopened = try WorkspaceStore(directory: directory).load()
        XCTAssertEqual(reopened.collections.first?.requests.first?.examples, request.examples)
    }
}
