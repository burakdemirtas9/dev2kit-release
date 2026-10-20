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

    @MainActor
    func testManyRequestsAreSummarized() {
        let requests = (1...12).map { RequestModel(name: "r\($0)", url: "https://api.example.com", auth: .bearer(token: "SYNTHETIC-\($0)")) }
        let message = AppState.exportMessage(collection: CollectionModel(name: "c", requests: requests), fileName: "c.json")
        XCTAssertEqual(message.lines.filter { $0.kind == .warning }.count, 9, "8 satır + '… ve 4 daha'")
    }
}
