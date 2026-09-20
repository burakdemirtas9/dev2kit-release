import XCTest
@testable import Dev2KitCore

final class ImportReviewerTests: XCTestCase {
    private let context = ImportReviewer.Context(policy: .notConfigured, vaultSecretNames: ["prod_token"])

    private func findings(_ request: RequestModel, policy: HostPolicyState = .notConfigured) -> [ImportFinding] {
        ImportReviewer.review(request, context: .init(policy: policy, vaultSecretNames: context.vaultSecretNames))
    }

    private func titles(_ request: RequestModel, _ severity: ImportFinding.Severity, policy: HostPolicyState = .notConfigured) -> [String] {
        findings(request, policy: policy).filter { $0.severity == severity }.map(\.title)
    }

    func testCleanRequestHasNoFindings() {
        XCTAssertEqual(findings(RequestModel(url: "https://api.example.com/users")), [])
    }

    // MARK: - Kesin engel

    func testFileSchemeIsBlocked() {
        XCTAssertEqual(titles(RequestModel(url: "file:///etc/passwd"), .block), ["Desteklenmeyen adres türü"])
    }

    func testLiteralHostOutsidePolicyIsBlocked() {
        let policy = HostPolicyState.active(HostPolicy(allowedHosts: ["*.firma.local"]))
        XCTAssertEqual(titles(RequestModel(url: "https://evil.com:8443/x"), .block, policy: policy), ["Yönetici politikası"])
        XCTAssertEqual(titles(RequestModel(url: "https://api.firma.local/x"), .block, policy: policy), [])
    }

    func testTemplatedHostIsLeftForSendTime() {
        let policy = HostPolicyState.active(HostPolicy(allowedHosts: ["*.firma.local"]))
        XCTAssertEqual(findings(RequestModel(url: "{{baseUrl}}/x"), policy: policy), [])
        XCTAssertEqual(findings(RequestModel(url: "https://{{host}}/x"), policy: policy), [])
    }

    func testHiddenCharactersInHeaderAreBlocked() {
        let request = RequestModel(url: "https://a.com", headers: [KeyValueEntry(key: "X-A", value: "1\r\nX-Admin: true")])
        XCTAssertEqual(titles(request, .block), ["Görünmez karakter"])
    }

    // MARK: - Dikkat

    func testUsingAVaultSecretIsFlaggedWithDestination() throws {
        let request = RequestModel(url: "https://toplayici.example/x", headers: [KeyValueEntry(key: "X-Token", value: "{{secret:prod_token}}")])
        let finding = try XCTUnwrap(findings(request).first { $0.title == "Vault'undaki secret'ı kullanıyor" })
        XCTAssertTrue(finding.detail.contains("toplayici.example"))
    }

    func testUnknownSecretNameIsNotFlaggedAsVaultUse() {
        let request = RequestModel(url: "https://a.com", headers: [KeyValueEntry(key: "X-Token", value: "{{secret:baska}}")])
        XCTAssertFalse(titles(request, .warn).contains("Vault'undaki secret'ı kullanıyor"))
    }

    func testPlaintextCredentialsAreLocated() throws {
        let request = RequestModel(
            url: "https://a.com",
            headers: [
                KeyValueEntry(key: "Cookie", value: "oturum=abc123"),
                KeyValueEntry(key: "X-Token", value: "{{secret:prod_token}}"),
            ],
            body: .raw(content: #"{"key":"AKIAABCDEFGHIJKLMNOP"}"#, contentType: "application/json"),
            auth: .basic(username: "ali", password: "parola")
        )
        let detail = try XCTUnwrap(findings(request).first { $0.title == "Düz metin kimlik bilgisi" }).detail
        XCTAssertTrue(detail.contains("Basic auth parolası"))
        XCTAssertTrue(detail.contains("\"Cookie\" başlığı"))
        XCTAssertTrue(detail.contains("gövde"))
        XCTAssertFalse(detail.contains("X-Token"), "secret referansı düz metin değil")
    }

    func testTokenPatterns() {
        XCTAssertTrue(ImportReviewer.containsTokenPattern("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.imza"))
        XCTAssertTrue(ImportReviewer.containsTokenPattern("-----BEGIN RSA PRIVATE KEY-----"))
        XCTAssertTrue(ImportReviewer.containsTokenPattern("token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(ImportReviewer.containsTokenPattern(#"{"kod":"USD","tutar":100}"#))
    }

    func testCleartextCredentialsWarnExceptLoopback() {
        let remote = RequestModel(url: "http://api.example.com", auth: .bearer(token: "{{secret:prod_token}}"))
        XCTAssertTrue(titles(remote, .warn).contains("Kimlik bilgisi şifresiz gidecek"))
        let local = RequestModel(url: "http://localhost:8080", auth: .bearer(token: "{{secret:prod_token}}"))
        XCTAssertFalse(titles(local, .warn).contains("Kimlik bilgisi şifresiz gidecek"))
    }

    func testMetadataPunycodeAndUserInfo() {
        XCTAssertTrue(titles(RequestModel(url: "http://169.254.169.254/latest"), .warn).contains("Bulut metadata adresi"))
        XCTAssertTrue(titles(RequestModel(url: "https://xn--pypal-4ve.com"), .warn).contains("Benzer görünen alan adı"))
        XCTAssertTrue(titles(RequestModel(url: "https://ali:parola@a.com"), .warn).contains("Adreste kullanıcı bilgisi"))
    }

    func testPersonalDataIsInformational() {
        let request = RequestModel(url: "https://a.com", headers: [KeyValueEntry(key: "x-identification-number", value: "12345678901")])
        XCTAssertEqual(titles(request, .info), ["Kişisel veri"])
    }

    // MARK: - Koleksiyon

    func testBlockedRequestsAreLeftOutOfTheImport() {
        let collection = CollectionModel(name: "K", requests: [
            RequestModel(name: "iyi", url: "https://a.com"),
            RequestModel(name: "kötü", url: "file:///etc/passwd"),
        ])
        let review = ImportReviewer.review(collection: collection, notes: [], context: context)
        XCTAssertEqual(review.blockedCount, 1)
        XCTAssertEqual(review.importableCollection.requests.map(\.name), ["iyi"])
        XCTAssertFalse(review.isClean)
    }

    func testCleanCollectionSkipsTheReviewScreen() {
        let review = ImportReviewer.review(
            collection: CollectionModel(name: "K", requests: [RequestModel(url: "https://a.com")]),
            notes: [],
            context: context
        )
        XCTAssertTrue(review.isClean)
    }

    func testPostmanScriptsAreReportedNotSilentlyDropped() throws {
        let json = """
        {
          "info": {"name": "Scriptli"},
          "event": [{"listen": "prerequest", "script": {"exec": ["pm.environment.set('a', 1)"]}}],
          "item": [
            {"name": "A", "request": {"method": "GET", "url": "https://a.com"},
             "event": [{"listen": "test", "script": {"exec": "pm.test('ok', () => {})"}},
                       {"listen": "prerequest", "script": {"exec": [""]}}]},
            {"name": "Klasör", "item": [
              {"name": "B", "request": {"method": "GET", "url": "https://b.com"},
               "event": [{"listen": "prerequest", "script": {"exec": ["console.log(1)"]}}]}
            ]}
          ]
        }
        """
        let outcome = try CollectionPorting.importPostman(Data(json.utf8), existingNames: [])
        let note = try XCTUnwrap(outcome.warnings.first { $0.contains("script") })
        XCTAssertTrue(note.hasPrefix("3 Postman script'i"), note)
    }
}
