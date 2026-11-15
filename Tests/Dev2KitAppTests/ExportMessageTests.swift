import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// F6: dışa aktarma mesajı dosyanın gerçek içeriğine bağlı.
final class ExportMessageTests: XCTestCase {
    override func invokeTest() { withLanguage(.english) { super.invokeTest() } }

    @MainActor
    func testLiteralCredentialMakesAWarningNotAReassurance() {
        let collection = CollectionModel(name: "Shop", requests: [
            RequestModel(name: "login", url: "https://api.example.com", auth: .bearer(token: "SYNTHETIC-PLAINTEXT")),
        ])
        let message = AppState.exportMessage(collection: collection, fileName: "shop.dev2kit.json")
        XCTAssertEqual(message.kind, .warning)
        XCTAssertTrue(message.lines.contains { $0.text.contains("“login”") && $0.text.contains("Bearer token") })
        XCTAssertFalse(message.lines.contains { $0.text == L10n.t("result.exported.secrets") },
                       "'secret yazılmadı' güvencesi verilmez")
    }

    @MainActor
    func testReferenceOnlyCollectionKeepsTheSuccessMessage() {
        let collection = CollectionModel(name: "Shop", requests: [
            RequestModel(name: "login", url: "https://api.example.com", auth: .bearer(token: "{{secret:token}}")),
        ])
        let message = AppState.exportMessage(collection: collection, fileName: "shop.dev2kit.json")
        XCTAssertEqual(message.kind, .success)
        XCTAssertTrue(message.lines.contains { $0.text == L10n.t("result.exported.secrets") })
    }

    /// Dosyaya yazılan her şey sayılır: gövdedeki parola ve kapalı satır için
    /// "secret yazılmadı" denmez (inceleme, 2026-11-14).
    @MainActor
    func testBodyPasswordAndDisabledRowAreWarnedAbout() {
        var login = RequestModel(name: "login", method: .post, url: "https://api.example.com/login")
        login.body = .raw(content: #"{"username": "u", "password": "SYNTHETIC-PASS"}"#, contentType: "application/json")
        var pay = RequestModel(name: "pay", url: "https://api.example.com/pay")
        pay.headers = [KeyValueEntry(key: "Authorization", value: "Bearer SYNTHETIC-0123456789abcdef", enabled: false)]
        let message = AppState.exportMessage(collection: CollectionModel(name: "Shop", requests: [login, pay]),
                                             fileName: "shop.dev2kit.json")
        XCTAssertEqual(message.kind, .warning)
        XCTAssertTrue(message.lines.contains { $0.text.contains("“login”") && $0.text.contains("password") })
        XCTAssertTrue(message.lines.contains { $0.text.contains("“pay”") && $0.text.contains("Authorization") })
        XCTAssertFalse(message.lines.contains { $0.text == L10n.t("result.exported.secrets") })
    }

    /// Yalnızca dosyaya giren şey için uyarılır: Postman biçimine kapalı query
    /// parametresi yazılmaz; dev2kit biçimine yazılır.
    @MainActor
    func testDisabledQueryParamIsWarnedOnlyWhereItIsWritten() throws {
        var request = RequestModel(name: "list", url: "https://api.example.com/list")
        request.queryParams = [KeyValueEntry(key: "access_token", value: "SYNTHETIC-0123456789abcdef", enabled: false)]
        let collection = CollectionModel(name: "Shop", requests: [request])

        XCTAssertFalse(String(decoding: try PostmanExporter.export(collection).data, as: UTF8.self).contains("SYNTHETIC-0123456789abcdef"))
        XCTAssertFalse(AppState.exportMessage(collection: collection, fileName: "shop.postman_collection.json", format: .postman)
            .lines.contains { $0.text.contains("access_token") })

        XCTAssertTrue(String(decoding: try CollectionPorting.exportData(collection), as: UTF8.self).contains("SYNTHETIC-0123456789abcdef"))
        XCTAssertTrue(AppState.exportMessage(collection: collection, fileName: "shop.dev2kit.json")
            .lines.contains { $0.text.contains("access_token") })
    }

    @MainActor
    func testManyRequestsAreSummarized() {
        let requests = (1...12).map { RequestModel(name: "r\($0)", url: "https://api.example.com", auth: .bearer(token: "SYNTHETIC-\($0)")) }
        let message = AppState.exportMessage(collection: CollectionModel(name: "c", requests: requests), fileName: "c.json")
        XCTAssertEqual(message.lines.filter { $0.kind == .warning }.count, 9, "8 satır + '… ve 4 daha'")
    }
}
