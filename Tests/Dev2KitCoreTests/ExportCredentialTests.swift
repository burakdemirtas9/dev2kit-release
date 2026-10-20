import XCTest
@testable import Dev2KitCore

/// Güvenlik incelemesi F6 (2026-10-20): dışa aktarılan dosyadaki düz metin
/// kimlik bilgisi tespit edilir; mesaj buna göre yazılır. Değerler sentetik.
final class ExportCredentialTests: XCTestCase {
    override func invokeTest() { withLanguage(.english) { super.invokeTest() } }

    func testLiteralCredentialsAreFoundPerRequest() {
        let collection = CollectionModel(name: "c", requests: [
            RequestModel(name: "bearer", url: "https://api.example.com", auth: .bearer(token: "SYNTHETIC-PLAINTEXT")),
            RequestModel(name: "header", url: "https://api.example.com",
                         headers: [KeyValueEntry(key: "X-Api-Key", value: "SYNTHETIC-KEY-0123456789abcdef")]),
            RequestModel(name: "oauth", url: "https://api.example.com",
                         auth: .oauth2(OAuth2Config(tokenURL: "https://idp.example.com/token", clientID: "c", clientSecret: "SYNTHETIC-CLIENT"))),
            RequestModel(name: "clean", url: "https://api.example.com", auth: .bearer(token: "{{secret:token}}")),
        ])
        let found = CollectionPorting.plaintextCredentials(in: collection)
        XCTAssertEqual(found.map(\.requestName), ["bearer", "header", "oauth"])
        XCTAssertEqual(found[0].places, ["Bearer token"])
        XCTAssertEqual(found[2].places, ["OAuth2 client secret"])
    }

    func testReferenceOnlyCollectionHasNoFindings() {
        let collection = CollectionModel(name: "c", requests: [
            RequestModel(url: "https://api.example.com", headers: [KeyValueEntry(key: "X-Api-Key", value: "{{secret:key}}")],
                         auth: .bearer(token: "{{accessToken}}")),
        ])
        XCTAssertTrue(CollectionPorting.plaintextCredentials(in: collection).isEmpty)
    }

    /// İncelemenin PoC'si: düz metin bearer token dışa aktarılan veride var
    /// (içerik değişmedi); artık bunu söyleyen tespit de var.
    func testExportedDataStillContainsTheLiteralAndItIsReported() throws {
        let collection = CollectionModel(name: "c", requests: [
            RequestModel(name: "r", url: "https://api.example.com", auth: .bearer(token: "SYNTHETIC-PLAINTEXT")),
        ])
        let text = String(decoding: try CollectionPorting.exportData(collection), as: UTF8.self)
        XCTAssertTrue(text.contains("SYNTHETIC-PLAINTEXT"))
        XCTAssertFalse(CollectionPorting.plaintextCredentials(in: collection).isEmpty)
    }
}
