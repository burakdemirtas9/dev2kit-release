import XCTest
@testable import Dev2KitCore

final class HostPolicyTests: XCTestCase {
    private func policy(_ json: String) -> HostPolicyState {
        HostPolicyLoader.parse(Data(json.utf8))
    }

    private func activePolicy(_ hosts: [String]) -> HostPolicy {
        HostPolicy(allowedHosts: hosts.map(HostPolicy.normalize))
    }

    // MARK: - Eşleşme

    func testExactHostMatchIsCaseInsensitiveAndIgnoresTrailingDot() {
        let policy = activePolicy(["api.partner.com"])
        XCTAssertTrue(policy.allows(host: "API.Partner.com"))
        XCTAssertTrue(policy.allows(host: "api.partner.com."))
        XCTAssertFalse(policy.allows(host: "partner.com"))
    }

    func testWildcardCoversSubdomainsButNotApexOrLookalikes() {
        let policy = activePolicy(["*.firma.local"])
        XCTAssertTrue(policy.allows(host: "api.firma.local"))
        XCTAssertTrue(policy.allows(host: "a.b.firma.local"))
        XCTAssertFalse(policy.allows(host: "firma.local"))
        XCTAssertFalse(policy.allows(host: "evilfirma.local"))
        XCTAssertFalse(policy.allows(host: "firma.local.evil.com"))
    }

    func testIPv6LiteralMatchesWithOrWithoutBrackets() {
        let policy = activePolicy(["::1"])
        XCTAssertTrue(policy.allows(host: "::1"))
        XCTAssertTrue(policy.allows(host: "[::1]"))
    }

    func testEmptyListAllowsNothing() {
        XCTAssertFalse(activePolicy([]).allows(host: "localhost"))
    }

    // MARK: - Dosya çözümleme

    func testValidFileBecomesActive() {
        XCTAssertEqual(
            policy(#"{"allowedHosts": ["*.Firma.local", "localhost"]}"#),
            .active(HostPolicy(allowedHosts: ["*.firma.local", "localhost"]))
        )
    }

    func testBrokenOrMisspelledFileFailsClosed() {
        for json in ["{bozuk", #"{"allowedHost": ["a.com"]}"#, #"{"allowedHosts": "a.com"}"#] {
            guard case .invalid = policy(json) else {
                return XCTFail("\(json) geçersiz sayılmalıydı")
            }
        }
    }

    func testAmbiguousPatternsAreRejected() {
        for pattern in ["*", "https://a.com", "a.com/yol", "kullanici@a.com", "", "*.", "a..com", "*.*.a.com"] {
            guard case .invalid = policy(#"{"allowedHosts": ["\#(pattern)"]}"#) else {
                return XCTFail("\"\(pattern)\" reddedilmeliydi")
            }
        }
    }

    func testInvalidStateBlocksEverything() {
        let state = HostPolicyState.invalid(reason: "bozuk")
        XCTAssertNotNil(state.violation(for: URL(string: "https://localhost")))
    }

    func testNotConfiguredAllowsEverything() {
        XCTAssertNil(HostPolicyState.notConfigured.violation(for: URL(string: "https://herhangi.com")))
    }

    // MARK: - Dosya yükleme

    private func temporaryPolicyFile(_ json: String, permissions: Int = 0o644) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("policy.json")
        try Data(json.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        return file
    }

    func testMissingFileMeansNotConfigured() {
        let url = URL(fileURLWithPath: "/tmp/dev2kit-yok-\(UUID().uuidString).json")
        XCTAssertEqual(HostPolicyLoader.load(from: url), .notConfigured)
    }

    func testFileNotOwnedByRootIsRejected() throws {
        let file = try temporaryPolicyFile(#"{"allowedHosts": ["a.com"]}"#)
        guard case .invalid(let reason) = HostPolicyLoader.load(from: file) else {
            return XCTFail("kullanıcıya ait dosya reddedilmeliydi")
        }
        XCTAssertTrue(reason.contains("root"))
    }

    func testWorldWritableFileIsRejectedEvenWithoutRootCheck() throws {
        let file = try temporaryPolicyFile(#"{"allowedHosts": ["a.com"]}"#, permissions: 0o666)
        guard case .invalid = HostPolicyLoader.load(from: file, requireRootOwnership: false) else {
            return XCTFail("herkesin yazabildiği dosya reddedilmeliydi")
        }
    }

    func testProperlyProtectedFileLoads() throws {
        let file = try temporaryPolicyFile(#"{"allowedHosts": ["a.com"]}"#)
        XCTAssertEqual(
            HostPolicyLoader.load(from: file, requireRootOwnership: false),
            .active(HostPolicy(allowedHosts: ["a.com"]))
        )
    }
}

final class RequestInspectorTests: XCTestCase {
    private let engine = RequestEngine()

    private func findings(
        _ model: RequestModel,
        variables: [String: String] = [:],
        secrets: [String: String] = ["token": "gizli-deger"],
        policy: HostPolicyState = .notConfigured
    ) throws -> [SecurityFinding] {
        let environment = EnvironmentModel(
            name: "test",
            variables: variables.map { KeyValueEntry(key: $0.key, value: $0.value) }
        )
        let resolver = VariableResolver(environment: environment, secretStore: InMemorySecretStore(initial: secrets))
        let request = try engine.buildURLRequest(model, resolver: resolver)
        return RequestInspector.inspect(model: model, request: request, environment: environment, policy: policy)
    }

    private func titles(_ findings: [SecurityFinding], _ severity: SecurityFinding.Severity) -> [String] {
        findings.filter { $0.severity == severity }.map(\.title)
    }

    func testPlainHTTPSRequestIsClean() throws {
        XCTAssertEqual(try findings(RequestModel(url: "https://api.example.com/users")), [])
    }

    // MARK: - Kesin engeller

    func testNonHTTPSchemesAreBlocked() throws {
        for url in ["file:///etc/passwd", "ftp://example.com/dosya"] {
            XCTAssertEqual(titles(try findings(RequestModel(url: url)), .block), ["Desteklenmeyen adres türü"], url)
        }
    }

    func testHostOutsidePolicyIsBlocked() throws {
        let policy = HostPolicyState.active(HostPolicy(allowedHosts: ["*.firma.local"]))
        XCTAssertEqual(titles(try findings(RequestModel(url: "https://api.firma.local/x"), policy: policy), .block), [])
        XCTAssertEqual(
            titles(try findings(RequestModel(url: "https://evil.com/x"), policy: policy), .block),
            ["Yönetici politikası"]
        )
    }

    func testHostHiddenBehindVariableIsStillChecked() throws {
        let policy = HostPolicyState.active(HostPolicy(allowedHosts: ["*.firma.local"]))
        let model = RequestModel(url: "{{baseUrl}}/users")
        let result = try findings(model, variables: ["baseUrl": "https://evil.com"], policy: policy)
        XCTAssertEqual(titles(result, .block), ["Yönetici politikası"])
    }

    func testBidiCharacterInURLIsBlocked() throws {
        let model = RequestModel(url: "https://api.example.com/\u{202E}fdp.exe")
        XCTAssertTrue(titles(try findings(model), .block).contains("Adreste görünmez karakter"))
    }

    func testHeaderInjectionThroughSecretValueIsBlocked() throws {
        let model = RequestModel(
            url: "https://api.example.com",
            headers: [KeyValueEntry(key: "X-Token", value: "{{secret:token}}")]
        )
        let resolver = VariableResolver(
            environment: nil,
            secretStore: InMemorySecretStore(initial: ["token": "a\r\nX-Admin: true"])
        )
        // Foundation bu başlığı sessizce düşürürdü; açık bir engel olmalı.
        XCTAssertThrowsError(try engine.buildURLRequest(model, resolver: resolver)) { error in
            guard case RequestEngineError.securityBlocked(let findings) = error else {
                return XCTFail("güvenlik engeli bekleniyordu: \(error)")
            }
            XCTAssertEqual(findings.map(\.title), ["Başlıkta satır sonu ya da görünmez karakter"])
        }
    }

    func testHeaderInjectionInTemplateIsBlocked() throws {
        let model = RequestModel(
            url: "https://api.example.com",
            headers: [KeyValueEntry(key: "X-Test", value: "a\u{200B}b")]
        )
        XCTAssertThrowsError(try findings(model))
    }

    // MARK: - Uyarılar

    func testCredentialsOverCleartextWarnButLoopbackDoesNot() throws {
        let remote = RequestModel(url: "http://api.example.com", auth: .bearer(token: "{{secret:token}}"))
        XCTAssertTrue(titles(try findings(remote), .warn).contains("Kimlik bilgisi şifresiz gidiyor"))

        let local = RequestModel(url: "http://127.0.0.1:8080", auth: .bearer(token: "{{secret:token}}"))
        XCTAssertFalse(titles(try findings(local), .warn).contains("Kimlik bilgisi şifresiz gidiyor"))
    }

    func testCleartextWithoutCredentialsIsFine() throws {
        XCTAssertEqual(try findings(RequestModel(url: "http://example.com/public")), [])
    }

    func testMetadataAddressWarns() throws {
        let result = try findings(RequestModel(url: "http://169.254.169.254/latest/meta-data/"))
        XCTAssertEqual(titles(result, .warn), ["Bulut metadata adresi"])
    }

    func testPunycodeHostWarns() throws {
        let result = try findings(RequestModel(url: "https://xn--pypal-4ve.com/login"))
        XCTAssertEqual(titles(result, .warn), ["Benzer görünen alan adı"])
    }

    func testUserInfoInURLWarns() throws {
        let result = try findings(RequestModel(url: "https://ali:parola@api.example.com"))
        XCTAssertTrue(titles(result, .warn).contains("Adreste kullanıcı bilgisi"))
    }

    func testSecretInQueryWarns() throws {
        let model = RequestModel(
            url: "https://api.example.com",
            queryParams: [KeyValueEntry(key: "api_key", value: "{{secret:token}}")]
        )
        XCTAssertTrue(titles(try findings(model), .warn).contains("Secret adreste"))
    }

    func testEverySecretHostPairNeedsItsOwnApproval() throws {
        let model = RequestModel(
            url: "https://API.example.com",
            headers: [KeyValueEntry(key: "X-Token", value: "{{secret:token}}")]
        )
        let keys = try findings(model).compactMap(\.approvalKey)
        XCTAssertEqual(keys, ["secret-host|token|api.example.com"])
    }

    func testSecretUsedThroughEnvironmentVariableIsDetected() throws {
        let model = RequestModel(
            url: "https://api.example.com",
            headers: [KeyValueEntry(key: "Authorization", value: "{{authHeader}}")]
        )
        let result = try findings(model, variables: ["authHeader": "Bearer {{secret:token}}"])
        XCTAssertEqual(result.compactMap(\.approvalKey), ["secret-host|token|api.example.com"])
    }

    func testDisabledHeaderSecretIsIgnored() throws {
        let model = RequestModel(
            url: "https://api.example.com",
            headers: [KeyValueEntry(key: "X-Token", value: "{{secret:token}}", enabled: false)]
        )
        XCTAssertEqual(try findings(model), [])
    }

    // MARK: - Karar

    func testBlockWinsOverApproval() {
        let findings = [
            SecurityFinding(severity: .block, title: "engel", detail: ""),
            SecurityFinding(severity: .warn, title: "uyarı", detail: "", approvalKey: "k"),
        ]
        XCTAssertThrowsError(try RequestInspector.enforce(findings, approved: ["k"])) { error in
            guard case RequestEngineError.securityBlocked(let blocks) = error else {
                return XCTFail("engel bekleniyordu: \(error)")
            }
            XCTAssertEqual(blocks.map(\.title), ["engel"])
        }
    }

    func testOnlyUnapprovedWarningsArePending() {
        let findings = [
            SecurityFinding(severity: .warn, title: "a", detail: "", approvalKey: "a"),
            SecurityFinding(severity: .warn, title: "b", detail: "", approvalKey: "b"),
        ]
        XCTAssertThrowsError(try RequestInspector.enforce(findings, approved: ["a"])) { error in
            guard case RequestEngineError.needsApproval(let pending) = error else {
                return XCTFail("onay bekleniyordu: \(error)")
            }
            XCTAssertEqual(pending.map(\.title), ["b"])
        }
        XCTAssertNoThrow(try RequestInspector.enforce(findings, approved: ["a", "b"]))
    }

    /// Engel ağa çıkmadan önce uygulanır: bağlantı hiç açılmaz.
    func testEngineStopsBeforeTheNetwork() async {
        do {
            _ = try await engine.send(
                RequestModel(url: "file:///etc/passwd"),
                environment: nil,
                secretStore: InMemorySecretStore(),
                hostPolicy: .notConfigured
            )
            XCTFail("istek gönderilmemeliydi")
        } catch RequestEngineError.securityBlocked {
            // beklenen
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
    }

    // MARK: - Yönlendirme ve OAuth

    func testRedirectOutsidePolicyIsStopped() {
        let decision = RedirectGuard.evaluate(
            from: URL(string: "https://api.firma.local/a")!,
            to: URL(string: "https://evil.com/b")!,
            policy: .default,
            redirectCount: 0,
            hostPolicy: .active(HostPolicy(allowedHosts: ["*.firma.local"]))
        )
        XCTAssertEqual(decision, .stop(reason: .hostNotAllowed))
    }

    func testOAuthTokenEndpointOutsidePolicyIsRejected() {
        let policy = HostPolicyState.active(HostPolicy(allowedHosts: ["*.firma.local"]))
        XCTAssertNoThrow(try OAuth2Service.enforce(policy, on: "https://auth.firma.local/token"))
        XCTAssertThrowsError(try OAuth2Service.enforce(policy, on: "https://evil.com/token"))
    }
}

final class SecurityApprovalStoreTests: XCTestCase {
    private func store() -> SecurityApprovalStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev2kit-approvals-\(UUID().uuidString)")
            .appendingPathComponent("security-approvals.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return SecurityApprovalStore(fileURL: url)
    }

    func testApprovalsPersistAndAccumulate() throws {
        let store = store()
        XCTAssertEqual(store.load(), [])
        try store.approve(["a"])
        try store.approve(["b", "a"])
        XCTAssertEqual(store.load(), ["a", "b"])
    }

    func testFileIsPrivateToTheUser() throws {
        let store = store()
        try store.approve(["secret-host|token|api.example.com"])
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testResetForgetsEverything() throws {
        let store = store()
        try store.approve(["a"])
        try store.reset()
        XCTAssertEqual(store.load(), [])
    }

    func testCorruptFileMeansNoApprovals() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bozuk".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), [])
    }
}
