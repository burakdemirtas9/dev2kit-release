import XCTest
@testable import Dev2KitCore

/// Uydurma verilerle: gerçek log kişisel veri ve geçerli token içerdiği için
/// test verisi olarak kullanılmaz.
final class KibanaImporterTests: XCTestCase {
    private static let futureJWT = jwt(exp: Date().addingTimeInterval(86_400))
    private static let expiredJWT = jwt(exp: Date().addingTimeInterval(-3_600))

    private static func jwt(exp: Date) -> String {
        func encode(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(#"{"alg":"none"}"#)).\(encode(#"{"exp":\#(Int(exp.timeIntervalSince1970))}"#)).imza"
    }

    private func document(
        index: String = "test-incoming-log-2026.01.01-000001",
        path: String = "/ornek-service/islem/fiyat?=",
        method: String = "POST",
        body: String = #"{"kod":"USD"}"#,
        headers: [String: String]? = nil
    ) -> [String: Any] {
        [
            "_index": index,
            "_id": "abc",
            "_source": [
                "http_method": method,
                "request_path": path,
                "request_body": body,
                "service_name": "ornek-bff-service",
                "status_code": "200",
                "headers": headers ?? [
                    "host": "ornek-bff-service.test.svc.cluster.local:8080",
                    "content-length": "13",
                    "content-type": "application/json",
                    "accept": "application/json",
                    "x-device-os": "iOS",
                    "x-token-type": "Bearer",
                    "x-token-issued-at": "2026-01-01T10:00:00.000Z",
                    "x-token-provider": Self.expiredJWT,
                    "x-token-session-id": Self.futureJWT,
                    "cookie": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
                    "x-customer-name": "Ad",
                    "x-identification-number": "12345678901",
                    "x-ip-address": "10.0.0.1",
                    "x-forwarded-host": "gateway.ornek.com",
                    "x-b3-sessionid": "0b6f5c2e-1111-2222-3333-444455556666",
                    "traceparent": "00-abc-def-01",
                ],
            ] as [String: Any],
        ]
    }

    private func parse(_ object: Any) throws -> KibanaImporter.ParseResult {
        try KibanaImporter.parse(JSONSerialization.data(withJSONObject: object))
    }

    private func entry(_ object: Any = [:]) throws -> KibanaImporter.Entry {
        let input = (object as? [String: Any]).map { $0.isEmpty ? document() : $0 } ?? object
        return try XCTUnwrap(parse(input).entries.first)
    }

    private func category(_ name: String, in entry: KibanaImporter.Entry) -> HeaderCategory? {
        entry.headers.first { $0.id == name }?.category
    }

    // MARK: - Çözümleme

    func testURLUsesEnvironmentAndServiceVariableAndDropsEmptyQuery() throws {
        let entry = try entry()
        XCTAssertEqual(entry.method, .post)
        XCTAssertEqual(entry.environment, "test")
        XCTAssertEqual(entry.urlTemplate, "{{test-ornek-bff-service}}/ornek-service/islem/fiyat")
        XCTAssertEqual(entry.query, [])
    }

    func testRealQueryParametersAreKept() throws {
        let entry = try entry(document(path: "/a/b?limit=10&=bos&q=x%20y"))
        XCTAssertEqual(entry.query.map(\.key), ["limit", "q"])
        XCTAssertEqual(entry.query.map(\.value), ["10", "x y"])
    }

    func testSearchResponseAndArraysGiveMultipleEntries() throws {
        let search: [String: Any] = ["hits": ["hits": [document(), document(path: "/x")]]]
        XCTAssertEqual(try parse(search).entries.count, 2)
        XCTAssertEqual(try parse([document(), document()]).entries.count, 2)
    }

    func testFieldsAreUsedWhenSourceIsMissing() throws {
        let doc: [String: Any] = [
            "_index": "uat-incoming-log",
            "fields": [
                "http_method": ["GET"],
                "request_path": ["/durum"],
                "service_name": ["ornek-service"],
                "headers.accept": ["application/json"],
                "headers.accept.keyword": ["application/json"],
            ],
        ]
        let entry = try entry(doc)
        XCTAssertEqual(entry.urlTemplate, "{{uat-ornek-service}}/durum")
        XCTAssertEqual(entry.headers.map(\.id), ["accept"])
    }

    func testIndexPrefixesAreUnderstood() {
        XCTAssertEqual(KibanaImporter.environment(fromIndex: ".ds-prep-incoming-log-2026"), "prep")
        XCTAssertEqual(KibanaImporter.environment(fromIndex: "uzak-kume:test-incoming-log"), "test")
    }

    // MARK: - Ortam (yalnızca adlandırma; ret sebebi değil, 2026-10-20)

    func testAllEnvironmentsAreImported() throws {
        for (index, environment) in [
            ("test-incoming-log-2026", "test"),
            ("dev-incoming-log-2026", "dev"),
            ("staging-incoming-log-2026", "staging"),
            ("prod-incoming-log-2026", "prod"),
            ("production-incoming-log-2026", "production"),
            ("live-log", "live"),
        ] {
            let result = try parse(document(index: index))
            XCTAssertTrue(result.rejected.isEmpty, "\(index): \(result.rejected)")
            let entry = try XCTUnwrap(result.entries.first, index)
            XCTAssertEqual(entry.environment, environment)
            XCTAssertEqual(entry.urlTemplate, "{{\(environment)-ornek-bff-service}}/ornek-service/islem/fiyat")
        }
    }

    /// Ortamı anlaşılamayan ya da index'i olmayan kayıt da alınır; değişken
    /// yalnızca servis adı ("incoming" ortam sanılmaz).
    func testUnknownOrMissingEnvironmentIsImportedWithServiceVariable() throws {
        var withoutIndex = document()
        withoutIndex.removeValue(forKey: "_index")
        for doc in [document(index: "incoming-log-2026"), document(index: ""), withoutIndex] {
            let entry = try XCTUnwrap(parse(doc).entries.first)
            XCTAssertNil(entry.environment)
            XCTAssertEqual(entry.variableName, "ornek-bff-service")
            XCTAssertEqual(entry.urlTemplate, "{{ornek-bff-service}}/ornek-service/islem/fiyat")
        }
    }

    /// Prod kaydının alanları test kaydıyla aynı eşlemeden geçer; içerik
    /// değiştirilmez, eksiltilmez.
    func testProductionRecordKeepsTheSameMapping() throws {
        let test = try XCTUnwrap(parse(document()).entries.first)
        let prod = try XCTUnwrap(parse(document(index: "prod-incoming-log-2026")).entries.first)
        XCTAssertEqual(prod.method, test.method)
        XCTAssertEqual(prod.path, test.path)
        XCTAssertEqual(prod.query, test.query)
        XCTAssertEqual(prod.body, test.body)
        XCTAssertEqual(prod.headers.map(\.id), test.headers.map(\.id))
        XCTAssertEqual(prod.headers.map(\.value), test.headers.map(\.value))
        XCTAssertEqual(prod.loggedStatus, test.loggedStatus)
    }

    func testMixedExportImportsEveryEnvironment() throws {
        let result = try parse([document(), document(index: "prod-incoming-log"), document(index: "belirsiz")])
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertTrue(result.rejected.isEmpty)
    }

    /// Bozuk kayıt (zorunlu alan eksik) yine reddedilir; sebep ortam değil,
    /// eksik alan ve kayıt numarası.
    func testMalformedRecordsStillRejectedWithTheRealCause() throws {
        var noPath = document(index: "prod-incoming-log")
        noPath["_source"] = ["service_name": "ornek-bff-service"]
        var noService = document(index: "prod-incoming-log")
        noService["_source"] = ["request_path": "/x"]
        let result = try parse([document(), noPath, noService])
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.rejected, ["Kayıt 2: request_path yok.", "Kayıt 3: service_name yok; adres değişkeni türetilemiyor."])
    }

    func testNonKibanaJSONIsRejected() {
        XCTAssertThrowsError(try parse(["merhaba": "dünya"]))
        XCTAssertThrowsError(try KibanaImporter.parse(Data("bozuk".utf8)))
    }

    // MARK: - Başlık sınıflandırma

    func testHeadersAreGroupedConservatively() throws {
        let entry = try entry()
        XCTAssertEqual(category("host", in: entry), .dropped)
        XCTAssertEqual(category("content-length", in: entry), .dropped)
        XCTAssertEqual(category("content-type", in: entry), .normal)
        // Adında "token" geçse de değeri kimlik bilgisi değil.
        XCTAssertEqual(category("x-token-type", in: entry), .normal)
        XCTAssertEqual(category("x-token-issued-at", in: entry), .normal)
        XCTAssertEqual(category("x-token-session-id", in: entry), .sensitive)
        XCTAssertEqual(category("cookie", in: entry), .sensitive)
        XCTAssertEqual(category("x-identification-number", in: entry), .sensitive)
        // Proxy başlığı ama IP taşır.
        XCTAssertEqual(category("x-ip-address", in: entry), .sensitive)
        XCTAssertEqual(category("traceparent", in: entry), .infrastructure)
        XCTAssertEqual(category("x-forwarded-host", in: entry), .infrastructure)
        // Kullanıcının normal saydığı izleme başlığı; adında "session" geçse de token değil.
        XCTAssertEqual(category("x-b3-sessionid", in: entry), .normal)
    }

    func testUserApprovedHeadersAreNotSensitive() throws {
        let entry = try entry(document(headers: [
            "x-banking-customer-number": "123456789",
            "x-customer-external-user-id": "0b6f5c2e-1111-2222-3333-444455556666",
            "x-customer-first-login": "false",
            "x-customer-has-external-device": "false",
            "x-customer-kvkk-flag": "true",
            "x-getir-user-client-id": "65a1b2c3d4e5f6a7b8c9d0e1",
            "x-device-vendor-id": "0b6f5c2e-1111-2222-3333-444455556666",
            "x-customer-number": "0b6f5c2e-1111-2222-3333-444455556666",
            "x-correlation-id": "4f1c2a9b8e7d6c5b4a3f2e1d0c9b8a7f",
            "x-b3-sessionid": "0b6f5c2e-1111-2222-3333-444455556666",
            "x-b3-traceid": "4f1c2a9b8e7d6c5b",
        ]))
        let normal = Set(entry.headers.filter { $0.category == .normal }.map(\.id))
        XCTAssertEqual(normal.count, 9)
        XCTAssertFalse(normal.contains("x-b3-traceid"), "listede olmayan izleme başlığı proxy grubunda kalmalı")
        XCTAssertFalse(normal.contains("x-customer-number"), "listede olmayan müşteri başlığı hassas kalmalı")
    }

    func testTokenValueStaysInVaultEvenForApprovedName() {
        let header = HeaderClassifier.classify(name: "x-getir-user-client-id", value: Self.futureJWT)
        XCTAssertEqual(header.sensitiveKind, .credential)
    }

    func testJWTExpiryIsRead() throws {
        let entry = try entry()
        XCTAssertTrue(try XCTUnwrap(entry.headers.first { $0.id == "x-token-provider" }).isExpired())
        XCTAssertFalse(try XCTUnwrap(entry.headers.first { $0.id == "x-token-session-id" }).isExpired())
    }

    func testDefaultSelectionIsOnlyNormalHeaders() throws {
        let entry = try entry()
        XCTAssertEqual(
            entry.defaultHeaderSelection,
            ["accept", "content-type", "x-device-os", "x-token-type", "x-token-issued-at", "x-b3-sessionid"]
        )
    }

    // MARK: - İstek oluşturma

    func testNewRequestWithDefaults() throws {
        let entry = try entry()
        let output = KibanaImporter.build(entry, options: .init(selectedHeaders: entry.defaultHeaderSelection))
        XCTAssertEqual(output.request.url, "{{test-ornek-bff-service}}/ornek-service/islem/fiyat")
        XCTAssertEqual(output.request.method, .post)
        XCTAssertEqual(Set(output.request.headers.map(\.key)), entry.defaultHeaderSelection)
        XCTAssertTrue(output.secrets.isEmpty)
        guard case .raw(let content, let type) = output.request.body else { return XCTFail("gövde bekleniyordu") }
        XCTAssertEqual(type, "application/json")
        XCTAssertTrue(content.contains("\"kod\""))
    }

    func testCredentialsGoToVaultNeverIntoTheRequest() throws {
        let entry = try entry()
        let output = KibanaImporter.build(entry, options: .init(selectedHeaders: ["cookie", "x-token-session-id"]))
        XCTAssertEqual(output.secrets.map(\.name).sorted(), ["ornek-bff-service.cookie", "ornek-bff-service.x-token-session-id"])
        let values = output.request.headers.map(\.value)
        XCTAssertEqual(values.sorted(), ["{{secret:ornek-bff-service.cookie}}", "{{secret:ornek-bff-service.x-token-session-id}}"])
        XCTAssertFalse(values.contains(Self.futureJWT))
    }

    func testDroppedHeadersNeverComeThroughEvenIfSelected() throws {
        let entry = try entry()
        let output = KibanaImporter.build(entry, options: .init(selectedHeaders: ["host", "content-length"]))
        XCTAssertTrue(output.request.headers.isEmpty)
    }

    func testApplyingOnlyBodyKeepsTheRestOfTheRequest() throws {
        let entry = try entry()
        let base = RequestModel(
            name: "Benim isteğim",
            method: .put,
            url: "https://kendi.adresim/x",
            headers: [KeyValueEntry(key: "Accept", value: "text/plain"), KeyValueEntry(key: "X-Kendi", value: "1")],
            auth: .bearer(token: "{{secret:kendi}}")
        )
        var options = KibanaImporter.Options(selectedHeaders: ["accept"])
        options.includeURL = false
        let output = KibanaImporter.build(entry, options: options, onto: base)
        XCTAssertEqual(output.request.id, base.id)
        XCTAssertEqual(output.request.url, base.url)
        XCTAssertEqual(output.request.method, .put)
        XCTAssertEqual(output.request.auth, base.auth)
        // Aynı adlı başlık değişir (büyük/küçük harf fark etmez), diğerleri kalır.
        XCTAssertEqual(output.request.headers.map(\.key), ["X-Kendi", "accept"])
        XCTAssertEqual(output.request.headers.last?.value, "application/json")
    }
}
