import XCTest
@testable import Dev2KitCore

final class HistoryRedactorTests: XCTestCase {
    private let mask = HistoryRedactor.mask

    // MARK: - Referans korunur, ham değer maskelenir

    func testSecretReferenceIsKept() {
        var model = RequestModel(url: "https://a.example.com")
        model.auth = .bearer(token: "{{secret:token}}")
        let redacted = HistoryRedactor.redact(model)
        // Referans gizli değil: ne gönderdiğini anlamak için gerekli.
        XCTAssertEqual(redacted.auth, .bearer(token: "{{secret:token}}"))
    }

    func testLiteralBearerTokenIsMasked() {
        var model = RequestModel(url: "https://a.example.com")
        model.auth = .bearer(token: "eyJhbGciOiJIUzI1NiJ9.gercek.token")
        let redacted = HistoryRedactor.redact(model)
        XCTAssertEqual(redacted.auth, .bearer(token: mask))
    }

    func testBasicPasswordMaskedUsernameKept() {
        var model = RequestModel(url: "https://a.example.com")
        model.auth = .basic(username: "ali", password: "gercek-sifre")
        let redacted = HistoryRedactor.redact(model)
        XCTAssertEqual(redacted.auth, .basic(username: "ali", password: mask))
    }

    func testAPIKeyValueMaskedNameKept() {
        var model = RequestModel(url: "https://a.example.com")
        model.auth = .apiKey(key: "X-Api-Key", value: "ham-anahtar", location: .header)
        guard case .apiKey(let key, let value, _) = HistoryRedactor.redact(model).auth else {
            return XCTFail("apiKey bekleniyordu")
        }
        XCTAssertEqual(key, "X-Api-Key")
        XCTAssertEqual(value, mask)
    }

    // MARK: - Başlıklar

    func testCredentialHeadersMasked() {
        var model = RequestModel(url: "https://a.example.com")
        model.headers = [
            KeyValueEntry(key: "Authorization", value: "Bearer ham"),
            KeyValueEntry(key: "X-Api-Key", value: "ham-anahtar"),
            KeyValueEntry(key: "Cookie", value: "session=abc"),
            KeyValueEntry(key: "Accept", value: "application/json"),
        ]
        let redacted = HistoryRedactor.redact(model)
        XCTAssertEqual(redacted.headers[0].value, mask)
        XCTAssertEqual(redacted.headers[1].value, mask)
        XCTAssertEqual(redacted.headers[2].value, mask)
        // Gizli olmayan başlık aynen kalmalı; aksi halde geçmiş işe yaramaz.
        XCTAssertEqual(redacted.headers[3].value, "application/json")
    }

    func testHeaderNameMatchingIsCaseInsensitive() {
        var model = RequestModel(url: "https://a.example.com")
        model.headers = [KeyValueEntry(key: "authorization", value: "ham")]
        XCTAssertEqual(HistoryRedactor.redact(model).headers[0].value, mask)
    }

    // MARK: - URL

    func testURLCredentialParamsMasked() {
        let masked = HistoryRedactor.maskURL("https://a.example.com/v1/x?api_key=ham&sayfa=2")
        XCTAssertTrue(masked.contains("api_key=\(mask)"))
        XCTAssertTrue(masked.contains("sayfa=2"))
        XCTAssertTrue(masked.hasPrefix("https://a.example.com/v1/x?"))
    }

    func testURLWithoutQueryUnchanged() {
        let url = "https://a.example.com/v1/users"
        XCTAssertEqual(HistoryRedactor.maskURL(url), url)
    }

    func testURLSecretReferenceKept() {
        let masked = HistoryRedactor.maskURL("https://a.example.com?token={{secret:t}}")
        XCTAssertTrue(masked.contains("{{secret:t}}"))
    }

    // MARK: - Gövde

    func testJSONCredentialFieldsMasked() {
        let json = #"{"kullanici":"ali","password":"gizli123","sehir":"Ankara"}"#
        let redacted = HistoryRedactor.redactStructuredText(json)
        XCTAssertTrue(redacted.contains("\"password\": \"\(mask)\""))
        XCTAssertTrue(redacted.contains("\"kullanici\":\"ali\""))
        XCTAssertTrue(redacted.contains("\"sehir\":\"Ankara\""))
    }

    func testCamelCaseCredentialFieldMasked() {
        let json = #"{"accessToken":"abc","refresh_token":"def","ad":"ali"}"#
        let redacted = HistoryRedactor.redactStructuredText(json)
        XCTAssertFalse(redacted.contains("abc"))
        XCTAssertFalse(redacted.contains("def"))
        XCTAssertTrue(redacted.contains("ali"))
    }

    func testFormFieldsMasked() {
        var model = RequestModel(url: "https://a.example.com")
        model.body = .formURLEncoded(fields: [
            KeyValueEntry(key: "username", value: "ali"),
            KeyValueEntry(key: "password", value: "gizli"),
        ])
        guard case .formURLEncoded(let fields) = HistoryRedactor.redact(model).body else {
            return XCTFail("urlencoded bekleniyordu")
        }
        XCTAssertEqual(fields[0].value, "ali")
        XCTAssertEqual(fields[1].value, mask)
    }

    func testNonJSONBodyUntouched() {
        let text = "düz metin gövde"
        XCTAssertEqual(HistoryRedactor.redactStructuredText(text), text)
    }

    func testResponsePreviewIsTruncated() {
        let long = String(repeating: "x", count: 500)
        let result = HistoryRedactor.redactResponse(long, limit: 100)
        XCTAssertTrue(result.count < long.count)
        XCTAssertTrue(result.contains("kırpıldı"))
    }

    func testResponsePreviewMasksCredentials() {
        let body = #"{"access_token":"cok-gizli","ad":"ali"}"#
        let result = HistoryRedactor.redactResponse(body, limit: 10_000)
        XCTAssertFalse(result.contains("cok-gizli"))
        XCTAssertTrue(result.contains("ali"))
    }

    func testRedactionIsIdempotent() {
        var model = RequestModel(url: "https://a.example.com?api_key=ham")
        model.auth = .bearer(token: "ham")
        let once = HistoryRedactor.redact(model)
        let twice = HistoryRedactor.redact(once)
        XCTAssertEqual(once, twice)
    }
}

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev2kit-history-\(UUID().uuidString)")
        store = HistoryStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(
        name: String = "İstek",
        date: Date = Date(),
        environment: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            date: date,
            requestID: UUID(),
            requestName: name,
            collectionName: "Koleksiyon",
            environmentName: environment,
            method: .get,
            url: "https://a.example.com",
            outcome: .completed(status: 200, duration: 0.1, byteCount: 10, redirectCount: 0),
            snapshot: RequestModel()
        )
    }

    func testAppendAndRead() {
        store.append(entry(name: "Bir"), settings: .default)
        store.append(entry(name: "İki"), settings: .default)
        let all = store.entries()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.requestName, "İki", "en yeni başta olmalı")
    }

    func testDisabledSettingsSkipsWrite() {
        var settings = HistorySettings.default
        settings.isEnabled = false
        store.append(entry(), settings: settings)
        XCTAssertTrue(store.entries().isEmpty)
    }

    func testPersistsAcrossInstances() {
        store.append(entry(name: "Kalıcı"), settings: .default)
        let second = HistoryStore(directory: directory)
        XCTAssertEqual(second.entries().first?.requestName, "Kalıcı")
    }

    func testStoredFileIsEncrypted() throws {
        store.append(entry(name: "GizliIstekAdi"), settings: .default)
        let raw = try Data(contentsOf: directory.appendingPathComponent("history.enc"))
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("GizliIstekAdi"), "geçmiş diske düz metin yazılmamalı")
    }

    func testCountRetentionPrunes() {
        var settings = HistorySettings.default
        settings = HistorySettings(retentionCount: 3)
        for index in 0..<10 {
            store.append(entry(name: "\(index)", date: Date().addingTimeInterval(Double(index))), settings: settings)
        }
        XCTAssertEqual(store.entries().count, 3)
        XCTAssertEqual(store.entries().first?.requestName, "9")
    }

    func testAgeRetentionPrunes() {
        let settings = HistorySettings(retentionDays: 7)
        let old = entry(name: "Eski", date: Date().addingTimeInterval(-10 * 86_400))
        let fresh = entry(name: "Yeni")
        let pruned = HistoryStore.prune([old, fresh], settings: settings, now: Date())
        XCTAssertEqual(pruned.map(\.requestName), ["Yeni"])
    }

    func testDeleteByEnvironment() {
        store.append(entry(name: "Prod", environment: "Prod"), settings: .default)
        store.append(entry(name: "Dev", environment: "Dev"), settings: .default)
        store.deleteEntries(environmentName: "Prod")
        XCTAssertEqual(store.entries().map(\.requestName), ["Dev"])
    }

    func testDeleteAll() {
        store.append(entry(), settings: .default)
        store.deleteAll()
        XCTAssertTrue(store.entries().isEmpty)
    }

    func testDeleteSingle() {
        store.append(entry(name: "Bir"), settings: .default)
        store.append(entry(name: "İki"), settings: .default)
        guard let target = store.entries().first else { return XCTFail("kayıt yok") }
        store.delete(id: target.id)
        XCTAssertEqual(store.entries().map(\.requestName), ["Bir"])
    }

    func testCorruptFileDoesNotCrash() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("bozuk veri".utf8).write(to: directory.appendingPathComponent("history.enc"))
        let fresh = HistoryStore(directory: directory)
        XCTAssertTrue(fresh.entries().isEmpty, "bozuk dosya uygulamayı engellememeli")
    }
}

final class HistorySettingsTests: XCTestCase {
    func testValuesAreClamped() {
        XCTAssertEqual(HistorySettings(retentionCount: 0).retentionCount, 1)
        XCTAssertEqual(HistorySettings(retentionCount: 99_999).retentionCount, 5_000)
        XCTAssertEqual(HistorySettings(retentionDays: 0).retentionDays, 1)
        XCTAssertEqual(HistorySettings(retentionDays: 10_000).retentionDays, 365)
    }

    func testDefaultsMatchAgreedPolicy() {
        let settings = HistorySettings.default
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.retentionCount, 200)
        XCTAssertEqual(settings.retentionDays, 30)
        // Kullanıcı kararı (2026-10-19): varsayılan açık (önce kapalıydı).
        XCTAssertTrue(settings.storeResponseBodies, "yanıt gövdesi varsayılan olarak saklanır")
    }

    func testDecodingPartialSettingsFillsDefaults() throws {
        let json = #"{"retentionCount":50}"#
        let settings = try JSONDecoder().decode(HistorySettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.retentionCount, 50)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.retentionDays, 30)
    }
}

final class DirtyTrackingTests: XCTestCase {
    func testIdenticalRequestsAreFunctionallyEqual() {
        let a = RequestModel(method: .post, url: "https://a.example.com")
        var b = a
        b.id = UUID()
        XCTAssertTrue(a.isFunctionallyEqual(to: b))
    }

    func testRenameIsNotAFunctionalChange() {
        let a = RequestModel(name: "Eski", url: "https://a.example.com")
        var b = a
        b.name = "Yeni"
        // Yeniden adlandırmak gönderilecek şeyi değiştirmez.
        XCTAssertTrue(a.isFunctionallyEqual(to: b))
    }

    func testMethodChangeIsDetected() {
        let a = RequestModel(method: .get, url: "https://a.example.com")
        var b = a
        b.method = .post
        XCTAssertFalse(a.isFunctionallyEqual(to: b))
    }

    func testHeaderChangeIsDetected() {
        let a = RequestModel(url: "https://a.example.com")
        var b = a
        b.headers = [KeyValueEntry(key: "Accept", value: "application/json")]
        XCTAssertFalse(a.isFunctionallyEqual(to: b))
    }

    func testDisablingHeaderIsDetected() {
        var a = RequestModel(url: "https://a.example.com")
        a.headers = [KeyValueEntry(key: "Accept", value: "x", enabled: true)]
        var b = a
        b.headers[0].enabled = false
        XCTAssertFalse(a.isFunctionallyEqual(to: b))
    }

    func testCredentialChangeIsDetected() {
        var a = RequestModel(url: "https://a.example.com")
        a.auth = .bearer(token: "eski")
        var b = a
        b.auth = .bearer(token: "yeni")
        // Token değişimi de "test ettiğimden farklı" sayılmalı.
        XCTAssertFalse(a.isFunctionallyEqual(to: b))
    }

    func testOptionsChangeIsDetected() {
        let a = RequestModel(url: "https://a.example.com")
        var b = a
        b.options.timeout = 99
        XCTAssertFalse(a.isFunctionallyEqual(to: b))
    }

    func testBodyChangeIsDetected() {
        let a = RequestModel(url: "https://a.example.com")
        var b = a
        b.body = .raw(content: "{}", contentType: "application/json")
        XCTAssertFalse(a.isFunctionallyEqual(to: b))
    }
}

final class WorkspaceBaselineTests: XCTestCase {
    func testDecodingLegacyWorkspaceWithoutBaselines() throws {
        let json = #"{"schemaVersion":1,"collections":[],"environments":[]}"#
        let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: Data(json.utf8))
        XCTAssertTrue(workspace.sentBaselines.isEmpty)
        XCTAssertEqual(workspace.schemaVersion, 1)
    }

    func testBaselineRoundtrip() throws {
        var workspace = WorkspaceModel()
        let request = RequestModel(url: "https://a.example.com")
        workspace.collections = [CollectionModel(name: "K", requests: [request])]
        workspace.sentBaselines[request.id.uuidString] = request

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(WorkspaceModel.self, from: data)
        XCTAssertEqual(decoded.sentBaselines[request.id.uuidString]?.url, "https://a.example.com")
    }

    func testPruneDropsBaselinesOfDeletedRequests() {
        var workspace = WorkspaceModel()
        let live = RequestModel(url: "https://a.example.com")
        let deleted = RequestModel(url: "https://b.example.com")
        workspace.collections = [CollectionModel(name: "K", requests: [live])]
        workspace.sentBaselines[live.id.uuidString] = live
        workspace.sentBaselines[deleted.id.uuidString] = deleted

        workspace.pruneBaselines()
        XCTAssertEqual(Array(workspace.sentBaselines.keys), [live.id.uuidString])
    }
}

final class HistoryTrimmerTests: XCTestCase {
    func testShortBodyUntouched() {
        var model = RequestModel()
        model.body = .raw(content: "kısa", contentType: "text/plain")
        let trimmed = HistoryTrimmer.trim(model, maxBodyBytes: 1000)
        XCTAssertEqual(trimmed.body, .raw(content: "kısa", contentType: "text/plain"))
    }

    func testLargeBodyIsTruncated() {
        var model = RequestModel()
        model.body = .raw(content: String(repeating: "a", count: 5000), contentType: "application/json")
        guard case .raw(let content, let type) = HistoryTrimmer.trim(model, maxBodyBytes: 100).body else {
            return XCTFail("raw bekleniyordu")
        }
        XCTAssertLessThan(content.utf8.count, 5000)
        XCTAssertTrue(content.contains("kırpıldı"))
        XCTAssertEqual(type, "application/json", "content type korunmalı")
    }

    func testTruncationDoesNotSplitMultibyteCharacter() {
        // Türkçe karakterler 2 bayt; sınır ortasına denk gelse bile geçerli
        // bir metin üretilmeli.
        let text = String(repeating: "ğ", count: 100)
        for limit in 10...20 {
            let result = HistoryTrimmer.truncate(text, to: limit)
            XCTAssertFalse(result.isEmpty)
            // Geçerli bir String üretildiyse zaten çözümlenmiştir.
            XCTAssertTrue(result.contains("kırpıldı"))
        }
    }

    func testFormFieldsAreTrimmed() {
        var model = RequestModel()
        model.body = .formURLEncoded(fields: [
            KeyValueEntry(key: "a", value: String(repeating: "x", count: 10_000)),
        ])
        guard case .formURLEncoded(let fields) = HistoryTrimmer.trim(model, maxBodyBytes: 1000).body else {
            return XCTFail("urlencoded bekleniyordu")
        }
        XCTAssertLessThan(fields[0].value.utf8.count, 10_000)
    }

    func testBudgetKeepsNewestEntries() {
        func entry(_ name: String, _ date: Date) -> HistoryEntry {
            var model = RequestModel()
            model.body = .raw(content: String(repeating: "x", count: 4000), contentType: "text/plain")
            return HistoryEntry(
                date: date, requestID: UUID(), requestName: name,
                collectionName: nil, environmentName: nil, method: .get,
                url: "https://a.example.com",
                outcome: .completed(status: 200, duration: 0.1, byteCount: 1, redirectCount: 0),
                snapshot: model
            )
        }
        let now = Date()
        let entries = (0..<10).map { entry("kayit\($0)", now.addingTimeInterval(Double(-$0))) }
        let kept = HistoryTrimmer.fitToBudget(entries, maxTotalBytes: 12_000)
        XCTAssertLessThan(kept.count, 10)
        XCTAssertEqual(kept.first?.requestName, "kayit0", "en yeni kayıt korunmalı")
    }

    func testSingleOversizedEntryIsStillKept() {
        var model = RequestModel()
        model.body = .raw(content: String(repeating: "x", count: 50_000), contentType: "text/plain")
        let entry = HistoryEntry(
            requestID: UUID(), requestName: "dev", collectionName: nil,
            environmentName: nil, method: .post, url: "https://a.example.com",
            outcome: .failed(message: "x"), snapshot: model
        )
        // Tek kayıt bütçeyi aşsa bile geçmiş tamamen boşalmamalı.
        XCTAssertEqual(HistoryTrimmer.fitToBudget([entry], maxTotalBytes: 1000).count, 1)
    }

    func testSettingsSizeLimitsAreClamped() {
        XCTAssertEqual(HistorySettings(maxSnapshotBodyBytes: 10).maxSnapshotBodyBytes, 1024)
        XCTAssertEqual(HistorySettings(maxTotalBytes: 10).maxTotalBytes, 1_048_576)
        XCTAssertEqual(HistorySettings.default.maxSnapshotBodyBytes, 32_768)
        XCTAssertEqual(HistorySettings.default.maxTotalBytes, 10 * 1024 * 1024)
    }

    func testLegacySettingsGetSizeDefaults() throws {
        let json = #"{"retentionCount":50}"#
        let settings = try JSONDecoder().decode(HistorySettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.maxSnapshotBodyBytes, 32_768)
        XCTAssertEqual(settings.maxTotalBytes, 10 * 1024 * 1024)
    }
}
