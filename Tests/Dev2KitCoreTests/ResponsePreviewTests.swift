import XCTest
@testable import Dev2KitCore

final class ResponsePreviewTests: XCTestCase {
    private func data(_ bytes: [UInt8]) -> Data { Data(bytes) }
    private func text(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - Başlıktan

    func testHTMLContentType() {
        XCTAssertEqual(
            ResponsePreview.kind(contentType: "text/html; charset=utf-8", body: text("<p>x</p>")),
            .html
        )
    }

    func testImageContentType() {
        XCTAssertEqual(ResponsePreview.kind(contentType: "image/png", body: text("x")), .image)
        XCTAssertEqual(ResponsePreview.kind(contentType: "image/jpeg", body: text("x")), .image)
    }

    func testPDFContentType() {
        XCTAssertEqual(ResponsePreview.kind(contentType: "application/pdf", body: text("x")), .pdf)
    }

    func testSVGIsNotPreviewed() {
        // Script ve dış kaynak taşıyabilir; metin olarak göstermek daha güvenli.
        XCTAssertNil(ResponsePreview.kind(contentType: "image/svg+xml", body: text("<svg/>")))
    }

    func testJSONIsNotPreviewed() {
        XCTAssertNil(ResponsePreview.kind(contentType: "application/json", body: text("{}")))
    }

    func testXMLIsNotPreviewed() {
        // XML'in "gerçek görünümü" diye bir şey yok; renklendirilmiş metin zaten en iyisi.
        XCTAssertNil(ResponsePreview.kind(contentType: "application/xml", body: text("<a/>")))
    }

    func testEmptyBodyIsNotPreviewed() {
        XCTAssertNil(ResponsePreview.kind(contentType: "text/html", body: Data()))
    }

    // MARK: - Gövdeden tanıma

    func testPNGSignatureWithoutContentType() {
        let png = data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        XCTAssertEqual(ResponsePreview.kind(contentType: "", body: png), .image)
    }

    func testJPEGSignature() {
        XCTAssertEqual(
            ResponsePreview.kind(contentType: "application/octet-stream", body: data([0xFF, 0xD8, 0xFF, 0xE0])),
            .image
        )
    }

    func testGIFSignature() {
        XCTAssertEqual(ResponsePreview.kind(contentType: "", body: text("GIF89a...")), .image)
    }

    func testWebPSignature() {
        var body = Data("RIFF".utf8)
        body.append(contentsOf: [0, 0, 0, 0])
        body.append(Data("WEBPVP8 ".utf8))
        XCTAssertEqual(ResponsePreview.kind(contentType: "", body: body), .image)
    }

    func testPDFSignature() {
        XCTAssertEqual(ResponsePreview.kind(contentType: "", body: text("%PDF-1.7\n...")), .pdf)
    }

    func testHTMLSentAsPlainTextIsStillDetected() {
        XCTAssertEqual(
            ResponsePreview.kind(contentType: "text/plain", body: text("<!DOCTYPE html><html></html>")),
            .html
        )
    }

    func testPlainTextIsNotPreviewed() {
        XCTAssertNil(ResponsePreview.kind(contentType: "text/plain", body: text("merhaba")))
    }

    func testUnknownBinaryIsNotPreviewed() {
        XCTAssertNil(ResponsePreview.kind(contentType: "", body: data([0x00, 0x01, 0x02, 0x03])))
    }

    // MARK: - Boyut

    func testSizeLimit() {
        XCTAssertTrue(ResponsePreview.isWithinLimit(Data(repeating: 0, count: ResponsePreview.sizeLimit)))
        XCTAssertFalse(ResponsePreview.isWithinLimit(Data(repeating: 0, count: ResponsePreview.sizeLimit + 1)))
    }
}
