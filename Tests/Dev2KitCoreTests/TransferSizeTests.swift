import XCTest
@testable import Dev2KitCore

final class TransferSizeTests: XCTestCase {
    func testTotalsAddHeadersAndBody() {
        let size = TransferSize(requestHeaders: 251, requestBody: 1,
                                responseHeaders: 225, responseBody: 439, responseBodyDecoded: 439)
        XCTAssertEqual(size.requestTotal, 252)
        XCTAssertEqual(size.responseTotal, 664)
    }

    func testCompressionRatioWhenBodyWasCompressed() throws {
        let size = TransferSize(responseBody: 250, responseBodyDecoded: 1_000)
        let ratio = try XCTUnwrap(size.compressionRatio)
        XCTAssertEqual(ratio, 0.75, accuracy: 0.001)
    }

    func testNoRatioWhenNotCompressed() {
        // "%0 kazanç" yazmak yanıltıcı olurdu.
        XCTAssertNil(TransferSize(responseBody: 500, responseBodyDecoded: 500).compressionRatio)
        XCTAssertNil(TransferSize(responseBody: 0, responseBodyDecoded: 0).compressionRatio)
    }

    func testEmptyIsDetected() {
        XCTAssertTrue(TransferSize().isEmpty)
        XCTAssertFalse(TransferSize(responseHeaders: 1).isEmpty)
    }

    func testAdditionSumsRedirectHops() {
        // Yönlendirmede her adım ayrı işlem; toplam gerçekte giden veridir.
        let first = TransferSize(requestHeaders: 100, responseHeaders: 200, responseBody: 10, responseBodyDecoded: 10)
        let second = TransferSize(requestHeaders: 120, responseHeaders: 210, responseBody: 500, responseBodyDecoded: 900)
        let total = first + second
        XCTAssertEqual(total.requestHeaders, 220)
        XCTAssertEqual(total.responseBody, 510)
        XCTAssertEqual(total.responseBodyDecoded, 910)
    }
}
