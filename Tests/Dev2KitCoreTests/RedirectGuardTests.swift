import XCTest
@testable import Dev2KitCore

final class RedirectGuardTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: - Kaynak karşılaştırma

    func testSameOriginIsNotCrossOrigin() {
        XCTAssertFalse(RedirectGuard.isCrossOrigin(
            url("https://api.example.com/a"),
            url("https://api.example.com/b")
        ))
    }

    func testDifferentHostIsCrossOrigin() {
        XCTAssertTrue(RedirectGuard.isCrossOrigin(
            url("https://api.example.com/a"),
            url("https://evil.example.com/a")
        ))
    }

    func testSubdomainIsCrossOrigin() {
        // Alt alan adı ele geçirilirse token oraya taşınmamalı.
        XCTAssertTrue(RedirectGuard.isCrossOrigin(
            url("https://api.firma.com/a"),
            url("https://auth.firma.com/a")
        ))
    }

    func testDifferentSchemeIsCrossOrigin() {
        XCTAssertTrue(RedirectGuard.isCrossOrigin(
            url("https://api.example.com/a"),
            url("http://api.example.com/a")
        ))
    }

    func testDifferentPortIsCrossOrigin() {
        XCTAssertTrue(RedirectGuard.isCrossOrigin(
            url("https://api.example.com:8443/a"),
            url("https://api.example.com/a")
        ))
    }

    func testDefaultPortMatchesExplicitPort() {
        XCTAssertFalse(RedirectGuard.isCrossOrigin(
            url("https://api.example.com:443/a"),
            url("https://api.example.com/a")
        ))
    }

    func testHostComparisonIsCaseInsensitive() {
        XCTAssertFalse(RedirectGuard.isCrossOrigin(
            url("https://API.Example.com/a"),
            url("https://api.example.com/a")
        ))
    }

    // MARK: - Karar mantığı

    func testSameOriginRedirectKeepsHeaders() {
        let decision = RedirectGuard.evaluate(
            from: url("https://api.example.com/a"),
            to: url("https://api.example.com/b"),
            policy: .default,
            redirectCount: 0
        )
        XCTAssertEqual(decision, .follow(strippedHeaders: []))
    }

    func testCrossOriginRedirectStripsCredentials() {
        let decision = RedirectGuard.evaluate(
            from: url("https://api.example.com/a"),
            to: url("https://baska.example.net/a"),
            policy: .default,
            redirectCount: 0
        )
        guard case .follow(let stripped) = decision else {
            return XCTFail("follow bekleniyordu")
        }
        XCTAssertTrue(stripped.contains("Authorization"))
        XCTAssertTrue(stripped.contains("Cookie"))
        XCTAssertTrue(stripped.contains("Proxy-Authorization"))
    }

    func testHTTPSToHTTPDowngradeBlockedByDefault() {
        let decision = RedirectGuard.evaluate(
            from: url("https://api.example.com/a"),
            to: url("http://api.example.com/a"),
            policy: .default,
            redirectCount: 0
        )
        XCTAssertEqual(decision, .stop(reason: .insecureDowngrade))
    }

    func testDowngradeAllowedWhenExplicitlyEnabled() {
        let policy = RedirectPolicy(follow: true, maxRedirects: 10, allowInsecureDowngrade: true)
        let decision = RedirectGuard.evaluate(
            from: url("https://api.example.com/a"),
            to: url("http://api.example.com/a"),
            policy: policy,
            redirectCount: 0
        )
        // İzin verilse bile kaynak değiştiği için kimlik başlıkları düşer.
        guard case .follow(let stripped) = decision else {
            return XCTFail("follow bekleniyordu")
        }
        XCTAssertTrue(stripped.contains("Authorization"))
    }

    func testHTTPToHTTPSUpgradeAllowed() {
        let decision = RedirectGuard.evaluate(
            from: url("http://api.example.com/a"),
            to: url("https://api.example.com/a"),
            policy: .default,
            redirectCount: 0
        )
        guard case .follow = decision else {
            return XCTFail("yükseltmeye izin verilmeli")
        }
    }

    func testFollowDisabledStopsImmediately() {
        let policy = RedirectPolicy(follow: false)
        let decision = RedirectGuard.evaluate(
            from: url("https://a.example.com"),
            to: url("https://a.example.com/b"),
            policy: policy,
            redirectCount: 0
        )
        XCTAssertEqual(decision, .stop(reason: .policyDisabled))
    }

    func testRedirectLimitEnforced() {
        let policy = RedirectPolicy(follow: true, maxRedirects: 3)
        XCTAssertEqual(
            RedirectGuard.evaluate(
                from: url("https://a.example.com"),
                to: url("https://a.example.com/b"),
                policy: policy,
                redirectCount: 3
            ),
            .stop(reason: .tooManyRedirects)
        )
        guard case .follow = RedirectGuard.evaluate(
            from: url("https://a.example.com"),
            to: url("https://a.example.com/b"),
            policy: policy,
            redirectCount: 2
        ) else {
            return XCTFail("sınırın altında izlenmeli")
        }
    }

    func testMaxRedirectsIsClamped() {
        XCTAssertEqual(RedirectPolicy(maxRedirects: 9999).maxRedirects, 20)
        XCTAssertEqual(RedirectPolicy(maxRedirects: -5).maxRedirects, 0)
    }
}

final class RequestOptionsTests: XCTestCase {
    func testTimeoutIsClamped() {
        XCTAssertEqual(RequestOptions(timeout: 0).timeout, 1)
        XCTAssertEqual(RequestOptions(timeout: 100_000).timeout, 300)
        XCTAssertEqual(RequestOptions(timeout: 45).timeout, 45)
    }

    func testDecodingLegacyRequestWithoutOptions() throws {
        // Options alanı eklenmeden önce yazılmış workspace kayıtları.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Eski","method":"GET","url":"https://a.example.com"}
        """
        let request = try JSONDecoder().decode(RequestModel.self, from: Data(json.utf8))
        XCTAssertEqual(request.options.timeout, 30)
        XCTAssertTrue(request.options.redirect.follow)
        XCTAssertFalse(request.options.redirect.allowInsecureDowngrade)
        XCTAssertTrue(request.options.sendCookies)
        XCTAssertEqual(request.headers, [])
    }

    func testDecodingPartialOptionsFillsDefaults() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Kısmi","method":"GET","url":"https://a.example.com",
         "options":{"timeout":12}}
        """
        let request = try JSONDecoder().decode(RequestModel.self, from: Data(json.utf8))
        XCTAssertEqual(request.options.timeout, 12)
        XCTAssertTrue(request.options.redirect.follow)
        XCTAssertEqual(request.options.redirect.maxRedirects, 10)
    }

    func testRoundtripPreservesOptions() throws {
        var request = RequestModel(url: "https://a.example.com")
        request.options = RequestOptions(
            timeout: 7,
            redirect: RedirectPolicy(follow: false, maxRedirects: 2, allowInsecureDowngrade: true),
            sendCookies: false
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RequestModel.self, from: data)
        XCTAssertEqual(decoded.options, request.options)
    }
}

final class CredentialHeaderTests: XCTestCase {
    func testStandardHeadersAlwaysIncluded() {
        let names = RedirectGuard.credentialHeaders(for: RequestModel())
        XCTAssertTrue(names.contains("Authorization"))
        XCTAssertTrue(names.contains("Cookie"))
        XCTAssertTrue(names.contains("Proxy-Authorization"))
    }

    func testAPIKeyHeaderIncluded() {
        var model = RequestModel()
        model.auth = .apiKey(key: "X-Api-Key", value: "gizli", location: .header)
        XCTAssertTrue(RedirectGuard.credentialHeaders(for: model).contains("X-Api-Key"))
    }

    func testAPIKeyInQueryParamNotTreatedAsHeader() {
        var model = RequestModel()
        model.auth = .apiKey(key: "api_key", value: "gizli", location: .queryParam)
        XCTAssertFalse(RedirectGuard.credentialHeaders(for: model).contains("api_key"))
    }

    func testSecretBackedHeaderIncluded() {
        var model = RequestModel()
        model.headers = [
            KeyValueEntry(key: "X-Auth-Token", value: "{{secret:token}}"),
            KeyValueEntry(key: "Accept", value: "application/json"),
        ]
        let names = RedirectGuard.credentialHeaders(for: model)
        XCTAssertTrue(names.contains("X-Auth-Token"))
        XCTAssertFalse(names.contains("Accept"), "gizli olmayan başlık düşürülmemeli")
    }

    func testDisabledSecretHeaderIgnored() {
        var model = RequestModel()
        model.headers = [KeyValueEntry(key: "X-Kapali", value: "{{secret:t}}", enabled: false)]
        XCTAssertFalse(RedirectGuard.credentialHeaders(for: model).contains("X-Kapali"))
    }

    func testDuplicatesRemovedCaseInsensitively() {
        var model = RequestModel()
        model.auth = .apiKey(key: "authorization", value: "x", location: .header)
        let names = RedirectGuard.credentialHeaders(for: model)
        XCTAssertEqual(names.filter { $0.lowercased() == "authorization" }.count, 1)
    }

    func testCredentialHeadersStrippedOnlyCrossOrigin() {
        var model = RequestModel()
        model.auth = .apiKey(key: "X-Api-Key", value: "gizli", location: .header)
        let headers = RedirectGuard.credentialHeaders(for: model)

        let sameOrigin = RedirectGuard.evaluate(
            from: URL(string: "https://a.example.com/1")!,
            to: URL(string: "https://a.example.com/2")!,
            policy: .default, redirectCount: 0, credentialHeaders: headers
        )
        XCTAssertEqual(sameOrigin, .follow(strippedHeaders: []))

        let crossOrigin = RedirectGuard.evaluate(
            from: URL(string: "https://a.example.com/1")!,
            to: URL(string: "https://b.example.com/2")!,
            policy: .default, redirectCount: 0, credentialHeaders: headers
        )
        XCTAssertEqual(crossOrigin, .follow(strippedHeaders: headers))
    }
}
