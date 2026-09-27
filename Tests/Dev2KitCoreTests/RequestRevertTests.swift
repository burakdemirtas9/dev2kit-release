import XCTest
@testable import Dev2KitCore

/// "Son gönderilen hale dön" ile "farklı mı" kontrolü aynı alan kümesini
/// kullanmalı; bu testler ikisinin birlikte kalmasını sağlar.
final class RequestRevertTests: XCTestCase {
    private func baseline() -> RequestModel {
        var request = RequestModel(url: "https://api.example.com/v1")
        request.name = "gönderilen"
        request.method = .post
        request.headers = [KeyValueEntry(key: "Accept", value: "application/json")]
        request.queryParams = [KeyValueEntry(key: "page", value: "1")]
        request.auth = .bearer(token: "t")
        return request
    }

    func testRevertMakesRequestFunctionallyEqual() {
        let reference = baseline()
        var edited = reference
        edited.url = "https://api.example.com/v2"
        edited.method = .delete
        edited.headers = []
        edited.auth = .none

        let reverted = edited.revertingFunctionalFields(to: reference)
        XCTAssertTrue(reverted.isFunctionallyEqual(to: reference))
    }

    func testIdentityAndNameSurviveRevert() {
        let reference = baseline()
        var edited = reference
        edited.name = "çalıştığım ad"
        edited.url = "https://baska"

        let reverted = edited.revertingFunctionalFields(to: reference)
        XCTAssertEqual(reverted.id, edited.id)
        XCTAssertEqual(reverted.name, "çalıştığım ad")
        XCTAssertEqual(reverted.url, reference.url)
    }

    func testRevertIsIdempotent() {
        let reference = baseline()
        var edited = reference
        edited.url = "https://baska"
        let once = edited.revertingFunctionalFields(to: reference)
        let twice = once.revertingFunctionalFields(to: reference)
        XCTAssertTrue(twice.isFunctionallyEqual(to: once))
    }
}
