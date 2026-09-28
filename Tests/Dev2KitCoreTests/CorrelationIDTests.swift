import XCTest
@testable import Dev2KitCore

final class CorrelationIDTests: XCTestCase {
    private func headers(_ pairs: [(String, String)]) -> [(name: String, value: String)] {
        pairs.map { (name: $0.0, value: $0.1) }
    }

    func testFindsCorrelationIDCaseInsensitively() throws {
        let match = try XCTUnwrap(CorrelationID.find(in: headers([("X-Correlation-Id", "abc-123")])))
        XCTAssertEqual(match.value, "abc-123")
        XCTAssertEqual(match.headerName, "X-Correlation-Id", "başlığın yanıttaki hali gösterilmeli")
    }

    func testMoreSpecificHeaderWins() throws {
        // x-correlation-id ile x-request-id aynı şey olmayabilir; kullanıcı ilkini arar.
        let match = try XCTUnwrap(CorrelationID.find(in: headers([
            ("X-Request-Id", "istek-1"),
            ("X-Correlation-Id", "korelasyon-1"),
        ])))
        XCTAssertEqual(match.value, "korelasyon-1")
    }

    func testTraceparentYieldsOnlyTraceID() throws {
        // W3C biçimi: 00-<trace-id>-<span-id>-<flags>. Log aramasında trace-id aranır.
        let match = try XCTUnwrap(CorrelationID.find(in: headers([
            ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
        ])))
        XCTAssertEqual(match.value, "4bf92f3577b34da6a3ce929d0e0e4736")
    }

    func testMalformedTraceparentIsKeptWhole() {
        XCTAssertEqual(CorrelationID.extractedValue(from: "bozuk", headerName: "traceparent"), "bozuk")
    }

    func testB3AndAmazonHeadersAreRecognised() throws {
        let b3 = try XCTUnwrap(CorrelationID.find(in: headers([("X-B3-TraceId", "b3-1")])))
        XCTAssertEqual(b3.value, "b3-1")
        let amazon = try XCTUnwrap(CorrelationID.find(in: headers([("X-Amzn-Trace-Id", "Root=1-abc")])))
        XCTAssertEqual(amazon.value, "Root=1-abc")
    }

    func testEmptyValueIsIgnored() {
        XCTAssertNil(CorrelationID.find(in: headers([("X-Correlation-Id", "   ")])))
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(CorrelationID.find(in: headers([("Content-Type", "application/json")])))
    }

    func testShorteningKeepsBothEnds() {
        XCTAssertEqual(CorrelationID.shortened("4bf92f3577b34da6a3ce929d0e0e4736"), "4bf92f…4736")
        XCTAssertEqual(CorrelationID.shortened("kisa"), "kisa")
    }
}
