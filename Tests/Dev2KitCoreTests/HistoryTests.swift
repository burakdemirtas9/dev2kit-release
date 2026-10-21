import XCTest
@testable import Dev2KitCore

final class HistoryRedactorTests: XCTestCase {
    /// Beklenen mesajlar Türkçe.
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

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
        store.waitForPendingWrites()
        let second = HistoryStore(directory: directory)
        XCTAssertEqual(second.entries().first?.requestName, "Kalıcı")
    }

    func testStoredFileIsEncrypted() throws {
        var secret = entry(name: "GizliIstekAdi")
        secret = HistoryEntry(requestID: nil, requestName: "GizliIstekAdi", collectionName: nil, environmentName: nil,
                              method: .post, url: "https://a.example.com", outcome: secret.outcome,
                              snapshot: RequestModel(body: .raw(content: "GizliGovde", contentType: "text/plain")),
                              responsePreview: "GizliYanit")
        store.append(secret, settings: .default)
        store.waitForPendingWrites()
        let files = try XCTUnwrap(FileManager.default.subpaths(atPath: directory.path))
            .map { directory.appendingPathComponent($0) }
            .filter { !$0.hasDirectoryPath && $0.pathExtension == "enc" }
        XCTAssertEqual(files.count, 2, "dizin + içerik dosyası")
        for file in files {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            for word in ["GizliIstekAdi", "GizliGovde", "GizliYanit"] {
                XCTAssertFalse(text.contains(word), "geçmiş diske düz metin yazılmamalı: \(file.lastPathComponent)")
            }
        }
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
    /// Beklenen mesajlar Türkçe.
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

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

/// Geçmiş dizin + içerik dosyaları (2026-10-21): liste içeriksiz yüklenir,
/// eski tek dosya taşınır, bozuk dizin silinmez, sahipsiz içerik temizlenir.
final class HistoryLayoutTests: XCTestCase {
    private var directory: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent("dev2kit-history2-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: directory)
    }

    private func entry(_ name: String, preview: String? = "yanıt", body: String = "{\"a\":1}", date: Date = Date()) -> HistoryEntry {
        HistoryEntry(date: date, requestID: UUID(), requestName: name, collectionName: nil, environmentName: nil,
                     method: .post, url: "https://api.example.test/x",
                     outcome: .completed(status: 200, duration: 0.1, byteCount: 10, redirectCount: 0),
                     snapshot: RequestModel(name: name, body: .raw(content: body, contentType: "application/json")),
                     responsePreview: preview)
    }

    private var bodies: URL { directory.appendingPathComponent("history/bodies") }

    func testListIsLoadedWithoutPayloadsAndDetailHasThem() throws {
        let store = HistoryStore(directory: directory)
        let original = entry("Detay", preview: "uzun yanıt", body: "{\"gövde\":true}")
        store.append(original, settings: .default)
        store.waitForPendingWrites()

        let reopened = HistoryStore(directory: directory)
        let listed = try XCTUnwrap(reopened.entries().first)
        XCTAssertNil(listed.responsePreview, "liste önizlemeyi taşımaz")
        XCTAssertEqual(listed.snapshot.body, .none, "liste istek gövdesini taşımaz")
        let full = try XCTUnwrap(reopened.fullEntry(id: original.id))
        XCTAssertEqual(full, original)
    }

    func testLegacySingleFileIsMigratedAndKeptAsBackup() throws {
        let legacy = (0..<5).map { entry("Eski \($0)", date: Date().addingTimeInterval(Double(-$0))) }
        try EncryptedJSONFile<[HistoryEntry]>(fileURL: directory.appendingPathComponent("history.enc"),
                                             keyURL: directory.appendingPathComponent(".history.key")).save(legacy)
        let store = HistoryStore(directory: directory)
        XCTAssertEqual(store.entries().map(\.id), legacy.map(\.id))
        XCTAssertEqual(store.fullEntry(id: legacy[2].id), legacy[2])
        XCTAssertFalse(manager.fileExists(atPath: directory.appendingPathComponent("history.enc").path))
        XCTAssertTrue(manager.fileExists(atPath: directory.appendingPathComponent("history.v1.enc").path), "eski dosya yedekte")
        // Yeniden açılış yeniden taşımaz, kayıt çoğalmaz.
        XCTAssertEqual(HistoryStore(directory: directory).entries().count, 5)
    }

    func testCorruptIndexIsSetAsideAndPreviousIndexIsUsed() throws {
        let store = HistoryStore(directory: directory)
        store.append(entry("Bir"), settings: .default)
        store.waitForPendingWrites()
        store.append(entry("İki"), settings: .default)
        store.waitForPendingWrites()
        let index = directory.appendingPathComponent("history/index.enc")
        try Data("bozuk".utf8).write(to: index)

        let reopened = HistoryStore(directory: directory)
        XCTAssertEqual(reopened.entries().map(\.requestName), ["Bir"], "önceki sağlam dizin")
        let aside = try XCTUnwrap(reopened.recoveryNotice)
        XCTAssertEqual(try Data(contentsOf: aside), Data("bozuk".utf8), "bozuk dizin silinmez, kenara alınır")
    }

    func testOrphanPayloadsAreRemovedAndReferencedOnesKept() throws {
        let store = HistoryStore(directory: directory)
        let kept = entry("Kalan")
        store.append(kept, settings: .default)
        store.waitForPendingWrites()
        let orphan = bodies.appendingPathComponent("\(UUID().uuidString).enc")
        try Data("sahipsiz".utf8).write(to: orphan)

        let reopened = HistoryStore(directory: directory)
        _ = reopened.entries()
        reopened.waitForPendingWrites()
        XCTAssertFalse(manager.fileExists(atPath: orphan.path))
        XCTAssertNotNil(reopened.fullEntry(id: kept.id)?.responsePreview)
    }

    func testPrunedEntriesLoseTheirPayloadFiles() throws {
        let store = HistoryStore(directory: directory)
        let settings = HistorySettings(retentionCount: 2)
        let first = entry("1", date: Date().addingTimeInterval(-3))
        for item in [first, entry("2", date: Date().addingTimeInterval(-2)), entry("3", date: Date().addingTimeInterval(-1))] {
            store.append(item, settings: settings)
        }
        store.waitForPendingWrites()
        XCTAssertEqual(store.entries().count, 2)
        XCTAssertFalse(manager.fileExists(atPath: bodies.appendingPathComponent("\(first.id.uuidString).enc").path))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: bodies.path).count, 2)
    }

    func testSizeBudgetCountsPayloads() throws {
        let store = HistoryStore(directory: directory)
        let settings = HistorySettings(maxTotalBytes: 1_000_000)
        let big = String(repeating: "x", count: 400_000)
        for index in 0..<5 { store.append(entry("\(index)", preview: big, date: Date().addingTimeInterval(Double(index))), settings: settings) }
        store.waitForPendingWrites()
        XCTAssertEqual(store.entries().count, 2, "içerik boyutu bütçeye sayılır")
    }

    /// Büyük geçmiş: liste yalnızca dizini okur; dizin içeriklerin yanında küçük kalır.
    func testLargeHistoryListStaysSmallAndFast() throws {
        let preview = String(repeating: "yanıt gövdesi ", count: 1_400) // ~20 KB
        let legacy = (0..<1_000).map { entry("İstek \($0)", preview: preview, date: Date().addingTimeInterval(Double(-$0))) }
        try EncryptedJSONFile<[HistoryEntry]>(fileURL: directory.appendingPathComponent("history.enc"),
                                             keyURL: directory.appendingPathComponent(".history.key")).save(legacy)
        _ = HistoryStore(directory: directory).entries() // taşı

        let start = Date()
        let reopened = HistoryStore(directory: directory)
        XCTAssertEqual(reopened.entries().count, 1_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "liste içerik okumadan açılmalı")
        let indexSize = try XCTUnwrap(manager.attributesOfItem(atPath: directory.appendingPathComponent("history/index.enc").path)[.size] as? Int)
        XCTAssertLessThan(indexSize, reopened.fileSizeBytes() / 10, "dizin, içeriklerin yanında küçük")
        XCTAssertEqual(reopened.fullEntry(id: legacy[500].id)?.responsePreview, preview)
    }
}
