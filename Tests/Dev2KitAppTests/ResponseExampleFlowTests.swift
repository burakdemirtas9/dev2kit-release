import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Response örneği akışları `AppState` üzerinden: kaydet (0–5), altıncı
/// denemede uyarı, sil ve devam et, yeniden adlandır, yeniden aç, örnekten
/// isteğe dönüş ve örnek açıkken HİÇBİR gönderim yolunun ağa çıkmaması.
@MainActor
final class ResponseExampleFlowTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }

    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    override func setUp() {
        super.setUp()
        harness = AppStateHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
        super.tearDown()
    }

    // MARK: - Yardımcılar

    /// İsteğe gelmiş canlı bir yanıt (ağa çıkmadan).
    private func receive(_ requestID: UUID, status: Int = 200, body: String = #"{"ok": true}"#,
                         headers: [(name: String, value: String)] = [("Content-Type", "application/json")]) {
        let data = ResponseData(statusCode: status, headers: headers, body: Data(body.utf8), duration: 0.1, finalURL: nil)
        state.responses[requestID] = .success(AppState.makeDisplay(data))
    }

    /// Kaydetme akışını başlatır ve görüntü hazırlanana kadar bekler.
    private func beginSaving(_ requestID: UUID) async throws {
        state.beginSavingExample(for: requestID)
        for _ in 0..<200 where state.pendingExampleSave?.phase == .preparing {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(state.pendingExampleSave?.phase, .preparing, "görüntü hazırlanmalıydı")
    }

    private func examples(_ requestID: UUID) -> [ResponseExample] {
        state.request(withID: requestID)?.examples ?? []
    }

    private func saveExample(_ requestID: UUID, name: String) async throws {
        try await beginSaving(requestID)
        XCTAssertEqual(state.pendingExampleSave?.phase, .naming)
        XCTAssertEqual(state.commitPendingExample(name: name), .added)
    }

    // MARK: - Kaydetme ve sınır

    func testNoResponseMeansNoSaveFlow() {
        let request = harness.addRequest(named: "boş")
        state.beginSavingExample(for: request.id)
        XCTAssertNil(state.pendingExampleSave, "yanıt yokken kaydetme başlamaz")

        state.responses[request.id] = .failure("bağlantı kurulamadı")
        state.beginSavingExample(for: request.id)
        XCTAssertNil(state.pendingExampleSave, "ağ hatası örnek olmaz")
        XCTAssertNil(state.exampleUnavailableReason(for: request.id))
    }

    func testSaveUpToFiveThenSixthShowsWarningAndChangesNothing() async throws {
        let request = harness.addRequest(named: "liste")
        for index in 1...5 {
            receive(request.id, status: 200 + index)
            try await saveExample(request.id, name: "örnek \(index)")
            XCTAssertEqual(examples(request.id).count, index)
        }
        let before = examples(request.id)

        receive(request.id, status: 500, body: "altıncı")
        try await beginSaving(request.id)
        XCTAssertEqual(state.pendingExampleSave?.phase, .limitWarning, "beşte uyarı kutusu")
        XCTAssertEqual(L10n.t("example.limit.message", language: .turkish),
                       "Bu request için en fazla 5 örnek kaydedebilirsiniz. Yeni bir örnek kaydetmek için mevcut örneklerden birini silin.")
        XCTAssertEqual(L10n.t("example.limit.message", language: .english),
                       "You can save up to 5 examples per request. Delete an existing example to save a new one.")

        // Uyarı aşamasında da kaydetme yazmaz.
        state.manageExamplesForPendingSave()
        XCTAssertEqual(state.commitPendingExample(name: "zorla"), .limitReached)
        XCTAssertEqual(examples(request.id), before, "hiçbir örnek silinmez ya da üzerine yazılmaz")
        XCTAssertEqual(state.pendingExampleSave?.phase, .limitWarning)

        state.cancelSavingExample()
        XCTAssertNil(state.pendingExampleSave)
        XCTAssertEqual(examples(request.id), before)
    }

    func testDeleteFromManagementThenContinueWithTheSameSnapshot() async throws {
        let request = harness.addRequest(named: "liste")
        for index in 1...5 {
            receive(request.id, status: 200)
            try await saveExample(request.id, name: "e\(index)")
        }
        receive(request.id, status: 418, body: "çaydanlık")
        try await beginSaving(request.id)
        XCTAssertEqual(state.pendingExampleSave?.phase, .limitWarning)
        state.manageExamplesForPendingSave()
        XCTAssertEqual(state.pendingExampleSave?.phase, .naming)

        // Bu arada yeni bir canlı yanıt gelse de kaydedilecek görüntü değişmez.
        receive(request.id, status: 200, body: "sonradan")
        let victim = examples(request.id)[1]
        state.deleteExample(AppState.ExampleRef(requestID: request.id, exampleID: victim.id))
        XCTAssertEqual(examples(request.id).count, 4)
        XCTAssertNotNil(state.pendingExampleSave?.snapshot, "silme bekleyen görüntüyü bozmaz")

        XCTAssertEqual(state.commitPendingExample(name: "yeni"), .added)
        let saved = try XCTUnwrap(examples(request.id).last)
        XCTAssertEqual(saved.name, "yeni")
        XCTAssertEqual(saved.statusCode, 418)
        XCTAssertEqual(saved.body, "çaydanlık")
        XCTAssertFalse(examples(request.id).contains { $0.id == victim.id })
    }

    func testSnapshotIsTakenAtStartAndDefaultNameIsEditable() async throws {
        let request = harness.addRequest(named: "liste")
        receive(request.id, status: 404, body: "yok")
        try await beginSaving(request.id)
        XCTAssertEqual(state.pendingExampleSave?.snapshot?.name, "404 Not Found")
        receive(request.id, status: 200, body: "başka")
        XCTAssertEqual(state.commitPendingExample(name: "  Bulunamadı  "), .added)
        XCTAssertEqual(examples(request.id).first?.name, "Bulunamadı")
        XCTAssertEqual(examples(request.id).first?.statusCode, 404)
        XCTAssertEqual(examples(request.id).first?.body, "yok")
    }

    func testRenameDeleteAndReopen() async throws {
        let request = harness.addRequest(named: "kalıcı")
        receive(request.id)
        try await saveExample(request.id, name: "ilk")
        receive(request.id, status: 201)
        try await saveExample(request.id, name: "ikinci")
        let ref = AppState.ExampleRef(requestID: request.id, exampleID: examples(request.id)[0].id)

        XCTAssertTrue(state.renameExample(ref, to: "yeniden"))
        XCTAssertFalse(state.renameExample(ref, to: "  "), "boş ad reddedilir")
        state.deleteExample(AppState.ExampleRef(requestID: request.id, exampleID: examples(request.id)[1].id))

        let saved = try harness.savedWorkspace()
        let reopened = saved.collections.flatMap(\.requests).first { $0.id == request.id }
        XCTAssertEqual(reopened?.examples.map(\.name), ["yeniden"], "uygulama yeniden açılınca korunur")
    }

    func testDeletingRequestRemovesExamplesAndClosesExampleView() async throws {
        let request = harness.addRequest(named: "silinecek")
        receive(request.id)
        try await saveExample(request.id, name: "e")
        state.openExample(AppState.ExampleRef(requestID: request.id, exampleID: examples(request.id)[0].id))
        XCTAssertNotNil(state.openExample)

        state.deleteRequests([request.id])
        XCTAssertNil(state.openExample)
        let saved = try harness.savedWorkspace()
        XCTAssertFalse(saved.collections.flatMap(\.requests).contains { $0.id == request.id })
    }

    func testTokenFactoryResponseCannotBeSaved() {
        state.addTokenFactoryRequest()
        let id = try! XCTUnwrap(state.selectedRequestID)
        receive(id, body: #"{"access_token": "x"}"#)
        XCTAssertEqual(state.exampleUnavailableReason(for: id), .tokenFactory)
        state.beginSavingExample(for: id)
        XCTAssertNil(state.pendingExampleSave)
    }

    // MARK: - Görüntüleme ve isteğe dönüş

    func testOpeningExampleLeavesRequestLiveResponseAndEditsUntouched() async throws {
        var request = harness.addRequest(named: "dokunma", url: "https://api.example.com/v1")
        request.headers = [KeyValueEntry(key: "X-Kaydedilmemiş", value: "1")]
        request.method = .post
        state.selectedRequest?.wrappedValue = request   // gecikmeli kayıt bekliyor
        receive(request.id, status: 200, body: "canlı")
        try await saveExample(request.id, name: "e")
        receive(request.id, status: 503, body: "en son canlı")
        let before = try XCTUnwrap(state.request(withID: request.id))

        state.openExample(AppState.ExampleRef(requestID: request.id, exampleID: examples(request.id)[0].id))
        XCTAssertEqual(state.openExampleContent?.example.body, "canlı")
        XCTAssertEqual(state.selectedRequestID, request.id)
        XCTAssertEqual(state.request(withID: request.id), before)
        guard case .success(let live) = state.lastResponse else { return XCTFail("canlı yanıt kaybolmamalı") }
        XCTAssertEqual(live.data.statusCode, 503)

        state.returnFromExample()
        XCTAssertNil(state.openExample)
        XCTAssertEqual(state.selectedRequestID, request.id)
        XCTAssertTrue(state.takeAddressFocus(), "Dene adres alanına odaklanır")
        let after = try XCTUnwrap(state.request(withID: request.id))
        XCTAssertEqual(after.method, .post)
        XCTAssertEqual(after.url, "https://api.example.com/v1")
        XCTAssertEqual(after.headers.map(\.key), ["X-Kaydedilmemiş"])
    }

    func testNoSendPathStartsANetworkRequestWhileExampleIsOpen() async throws {
        let request = harness.addRequest(named: "gönderme", url: "https://192.0.2.1/never")
        receive(request.id)
        try await saveExample(request.id, name: "e")
        let ref = AppState.ExampleRef(requestID: request.id, exampleID: examples(request.id)[0].id)
        let historyBefore = state.history.count
        let current = try XCTUnwrap(state.request(withID: request.id))

        // Gönder düğmesi / ⌘↩ / adres alanında ⏎ — hepsi `send` çağırır.
        let paths: [(String, () -> Void)] = [
            ("send", { self.state.send(current) }),
            ("token yenile", { self.state.send(current, refreshingTokens: true) }),
            ("token olmadan", { self.state.send(current, skippingTokens: true) }),
            ("sendWithoutTokens", { self.state.sendWithoutTokens(request.id) }),
            ("güvenlik onayı", { self.state.approveAndSend([]) }),
        ]
        for (name, path) in paths {
            state.openExample(ref)
            state.addressFocusPending = false
            path()
            XCTAssertTrue(state.inFlight.isEmpty, "\(name): ağ isteği başlamamalı")
            if case .loading = state.responses[request.id] ?? .idle { XCTFail("\(name): yükleniyor durumuna geçmemeli") }
            XCTAssertNil(state.openExample, "\(name): istek düzenleyicisine dönmeli")
            XCTAssertTrue(state.addressFocusPending, "\(name): adres alanına odaklanmalı")
        }
        XCTAssertEqual(state.history.count, historyBefore, "geçmişe gönderim yazılmamalı")
        XCTAssertNil(state.workspace.sentBaselines[request.id.uuidString])
    }

    func testSelectingAnotherRequestOrTabClosesExample() async throws {
        let first = harness.addRequest(named: "bir")
        receive(first.id)
        try await saveExample(first.id, name: "e")
        let second = harness.addRequest(named: "iki")
        state.openExample(AppState.ExampleRef(requestID: first.id, exampleID: examples(first.id)[0].id))
        XCTAssertEqual(state.selectedRequestID, first.id)

        state.selectedRequestID = second.id
        XCTAssertNil(state.openExample)

        state.openExample(AppState.ExampleRef(requestID: first.id, exampleID: examples(first.id)[0].id))
        state.applySelection([first.id], order: [first.id, second.id])
        XCTAssertNil(state.openExample, "listede isteğin kendisine tıklamak editöre döner")
    }

    // MARK: - Örnekler başka yerlere sızmaz

    func testBaselineHistoryAndTokenFactoryCopyCarryNoExamples() async throws {
        let request = harness.addRequest(named: "temiz")
        receive(request.id)
        try await saveExample(request.id, name: "e")
        let withExamples = try XCTUnwrap(state.request(withID: request.id))
        XCTAssertEqual(withExamples.examples.count, 1)

        state.recordBaseline(withExamples)
        XCTAssertEqual(state.workspace.sentBaselines[request.id.uuidString]?.examples, [])

        state.recordHistory(withExamples, outcome: .completed(status: 200, duration: 0, byteCount: 0, redirectCount: 0), responseText: nil)
        XCTAssertEqual(state.history.first?.snapshot.examples, [])

        state.copyToTokenFactory([request.id])
        XCTAssertTrue(state.workspace.tokenFactoryRequests.allSatisfy(\.examples.isEmpty))
    }

    func testDuplicateCopiesExamplesWithNewIDs() async throws {
        let request = harness.addRequest(named: "çoğalt")
        receive(request.id)
        try await saveExample(request.id, name: "e")
        state.duplicateRequest(request.id)
        let copyID = try XCTUnwrap(state.selectedRequestID)
        XCTAssertNotEqual(copyID, request.id)
        XCTAssertEqual(examples(copyID).map(\.name), ["e"])
        XCTAssertNotEqual(examples(copyID)[0].id, examples(request.id)[0].id)
    }

    // MARK: - Request tarafı ve düzenleme

    /// Örneğin request'i yanıtı üreten (son gönderilen) haldir; gönderimden
    /// sonra editörde yapılan değişiklik örneğe girmez.
    func testExampleCapturesTheSentRequestNotLaterEdits() async throws {
        var request = harness.addRequest(named: "gönderilen", url: "https://api.example.com/v1")
        state.recordBaseline(request)                    // gönderim anındaki hal
        request.url = "https://api.example.com/sonradan"
        state.selectedRequest?.wrappedValue = request    // gönderimden sonra düzenlendi
        receive(request.id)
        try await saveExample(request.id, name: "e")
        XCTAssertEqual(examples(request.id).first?.request?.url, "https://api.example.com/v1")
    }

    func testEditingExampleRequestAndResponseIsSavedAndNormalized() async throws {
        let request = harness.addRequest(named: "düzenle")
        receive(request.id)
        try await saveExample(request.id, name: "e")
        let ref = AppState.ExampleRef(requestID: request.id, exampleID: examples(request.id)[0].id)
        let binding = try XCTUnwrap(state.exampleBinding(ref))

        var edited = binding.wrappedValue
        edited.statusCode = 404
        edited.body = #"{"error": "yok"}"#
        edited.headers = [ResponseExample.Header(name: "Content-Type", value: "application/problem+json")]
        edited.request?.method = .delete
        edited.request?.url = "https://api.example.com/kayit/9"
        binding.wrappedValue = edited

        let saved = try XCTUnwrap(harness.savedWorkspace().collections.flatMap(\.requests).first { $0.id == request.id }?.examples.first)
        XCTAssertEqual(saved.statusCode, 404)
        XCTAssertEqual(saved.body, #"{"error": "yok"}"#)
        XCTAssertEqual(saved.contentType, "application/problem+json", "Content-Type header'dan eşitlenir")
        XCTAssertEqual(saved.request?.method, .delete)
        XCTAssertEqual(saved.request?.url, "https://api.example.com/kayit/9")
        XCTAssertEqual(state.request(withID: request.id)?.url, request.url, "ana istek değişmez")

        // Örnek silindikten sonra eski bağlama yazmak bir şey yapmaz.
        state.deleteExample(ref)
        binding.wrappedValue = edited
        XCTAssertTrue(examples(request.id).isEmpty)
    }

    // MARK: - İçe aktarma

    func testImportOverLimitRequiresSelectionAndNeverTrimsSilently() throws {
        var request = RequestModel(name: "çok", url: "https://api.example.com")
        request.examples = (0..<7).map { ResponseExample(name: "e\($0)", statusCode: 200) }
        let data = try CollectionPorting.exportData(CollectionModel(name: "İçe", requests: [request]))
        guard case .success(let prepared) = state.prepareImport(data, source: .dev2kit) else { return XCTFail("hazırlanmalıydı") }
        XCTAssertFalse(prepared.review.isClean, "seçim için inceleme ekranı açılmalı")

        let countBefore = state.workspace.collections.count
        let refused = state.commitImport([prepared])
        XCTAssertEqual(refused.kind, .error)
        XCTAssertEqual(state.workspace.collections.count, countBefore, "seçim yapılmadan hiçbir şey yazılmaz")

        let imported = prepared.review.importableCollection.requests[0]
        let chosen = Set([imported.examples[0].id, imported.examples[6].id])
        let resolved = try XCTUnwrap(prepared.review.applyingExampleSelection([imported.id: chosen]))
        state.commitImport([AppState.PreparedImport(review: resolved, wasRenamed: prepared.wasRenamed)])
        let added = try XCTUnwrap(state.workspace.collections.last)
        XCTAssertEqual(added.requests[0].examples.map(\.name), ["e0", "e6"])
    }
}
