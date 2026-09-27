import XCTest
@testable import Dev2KitCore

/// Geri yüklemenin tek kuralı: maskelenmiş sır isteğe ASLA yazılmaz.
final class HistoryRestoreTests: XCTestCase {
    private let mask = HistoryRedactor.mask

    private func request(url: String = "https://api.example.com") -> RequestModel {
        RequestModel(url: url)
    }

    func testPlainFieldsComeFromSnapshot() {
        var snapshot = request(url: "https://api.example.com/v2")
        snapshot.method = .put
        let restored = HistoryRestore.apply(snapshot, to: request())
        XCTAssertEqual(restored.url, "https://api.example.com/v2")
        XCTAssertEqual(restored.method, .put)
    }

    func testMaskedURLKeepsCurrentValue() {
        var snapshot = request(url: "https://api.example.com/\(mask)")
        snapshot.method = .get
        let current = request(url: "https://api.example.com/gercek")
        XCTAssertEqual(HistoryRestore.apply(snapshot, to: current).url, "https://api.example.com/gercek")
    }

    func testMaskedHeaderTakesCurrentValue() {
        var snapshot = request()
        snapshot.headers = [KeyValueEntry(key: "Authorization", value: mask)]
        var current = request()
        current.headers = [KeyValueEntry(key: "authorization", value: "Bearer gercek")]
        XCTAssertEqual(HistoryRestore.apply(snapshot, to: current).headers.first?.value, "Bearer gercek")
    }

    func testMaskedHeaderWithoutCounterpartBecomesEmpty() {
        // Maskeyi yazmaktansa boş bırakmak dürüst: kullanıcı eksiği görür.
        var snapshot = request()
        snapshot.headers = [KeyValueEntry(key: "X-Token", value: mask)]
        XCTAssertEqual(HistoryRestore.apply(snapshot, to: request()).headers.first?.value, "")
    }

    func testUnmaskedHeaderIsRestored() {
        var snapshot = request()
        snapshot.headers = [KeyValueEntry(key: "Accept", value: "application/json")]
        XCTAssertEqual(HistoryRestore.apply(snapshot, to: request()).headers.first?.value, "application/json")
    }

    func testMaskedAuthIsNotRestored() {
        var snapshot = request()
        snapshot.auth = .bearer(token: mask)
        var current = request()
        current.auth = .bearer(token: "gercek-token")
        XCTAssertEqual(HistoryRestore.apply(snapshot, to: current).auth, .bearer(token: "gercek-token"))
    }

    func testCleanAuthIsRestored() {
        var snapshot = request()
        snapshot.auth = .basic(username: "ali", password: "acik")
        let restored = HistoryRestore.apply(snapshot, to: request())
        XCTAssertEqual(restored.auth, .basic(username: "ali", password: "acik"))
    }

    func testContainsMaskCoversEveryAuthKind() {
        XCTAssertFalse(HistoryRestore.containsMask(.none))
        XCTAssertTrue(HistoryRestore.containsMask(.basic(username: "a", password: mask)))
        XCTAssertTrue(HistoryRestore.containsMask(.bearer(token: mask)))
        XCTAssertTrue(HistoryRestore.containsMask(.apiKey(key: "k", value: mask, location: .header)))
        XCTAssertFalse(HistoryRestore.containsMask(.bearer(token: "temiz")))
    }
}
