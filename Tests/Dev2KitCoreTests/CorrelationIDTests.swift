import XCTest
@testable import Dev2KitCore

final class CorrelationIDTests: XCTestCase {
    private func headers(_ pairs: [(String, String)]) -> [(name: String, value: String)] {
        pairs.map { (name: $0.0, value: $0.1) }
    }

    func testFindsB3TraceIDCaseInsensitively() throws {
        let match = try XCTUnwrap(CorrelationID.find(in: headers([("X-B3-TraceId", "463ac35c9f6413ad")])))
        XCTAssertEqual(match.value, "463ac35c9f6413ad")
        XCTAssertEqual(match.headerName, "X-B3-TraceId", "başlığın yanıttaki hali gösterilmeli")
        XCTAssertTrue(match.explanation.contains("B3"))
    }

    func testOtherTraceHeadersAreIgnored() throws {
        // Şimdilik yalnızca B3: gateway'in kimlikleri rozette yanlış değeri öne çıkarıyordu.
        XCTAssertNil(CorrelationID.find(in: headers([
            ("X-Request-Id", "istek-1"),
            ("X-Correlation-Id", "korelasyon-1"),
            ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
        ])))
        let match = try XCTUnwrap(CorrelationID.find(in: headers([
            ("X-Request-Id", "istek-1"),
            ("x-b3-traceid", "b3-1"),
        ])))
        XCTAssertEqual(match.value, "b3-1")
    }

    func testTraceparentExtractionYieldsOnlyTraceID() {
        // Listeye eklenirse hazır: W3C biçimi 00-<trace-id>-<span-id>-<flags>.
        XCTAssertEqual(
            CorrelationID.extractedValue(
                from: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                headerName: "traceparent"
            ),
            "4bf92f3577b34da6a3ce929d0e0e4736"
        )
    }

    func testMalformedTraceparentIsKeptWhole() {
        XCTAssertEqual(CorrelationID.extractedValue(from: "bozuk", headerName: "traceparent"), "bozuk")
    }

    func testUnknownHeaderGetsGenericExplanation() {
        XCTAssertFalse(CorrelationID.Match(headerName: "X-Trace-Id", value: "x").explanation.isEmpty)
    }

    func testEmptyValueIsIgnored() {
        XCTAssertNil(CorrelationID.find(in: headers([("X-B3-TraceId", "   ")])))
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(CorrelationID.find(in: headers([("Content-Type", "application/json")])))
    }

    func testShorteningKeepsBothEnds() {
        XCTAssertEqual(CorrelationID.shortened("4bf92f3577b34da6a3ce929d0e0e4736"), "4bf92f…4736")
        XCTAssertEqual(CorrelationID.shortened("kisa"), "kisa")
    }
}
