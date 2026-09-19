import XCTest
@testable import BoltDockCore

final class ResponseFileNameTests: XCTestCase {
    private func response(
        url: String? = "https://api.example.com/users",
        headers: [(name: String, value: String)] = [],
        body: Data = Data("{}".utf8)
    ) -> ResponseData {
        ResponseData(
            statusCode: 200,
            headers: headers,
            body: body,
            duration: 0.1,
            finalURL: url.flatMap(URL.init(string:))
        )
    }

    // MARK: - Öncelik sırası

    func testContentTypeGivesExtensionToExtensionlessPath() {
        let name = ResponseFileName.suggested(for: response(headers: [("Content-Type", "application/json; charset=utf-8")]))
        XCTAssertEqual(name, "users.json")
    }

    func testPathExtensionIsKept() {
        let name = ResponseFileName.suggested(for: response(
            url: "https://cdn.example.com/files/report.pdf?token=abc",
            headers: [("Content-Type", "application/octet-stream")]
        ))
        XCTAssertEqual(name, "report.pdf")
    }

    func testContentDispositionWins() {
        let name = ResponseFileName.suggested(for: response(headers: [
            ("Content-Type", "text/csv"),
            ("Content-Disposition", "attachment; filename=\"ocak-2026.csv\""),
        ]))
        XCTAssertEqual(name, "ocak-2026.csv")
    }

    func testEncodedDispositionNameIsPreferredAndDecoded() {
        let value = "attachment; filename=\"rapor.pdf\"; filename*=UTF-8''%C3%B6zet%20rapor.pdf"
        XCTAssertEqual(ResponseFileName.suggested(for: response(headers: [("content-disposition", value)])), "özet rapor.pdf")
    }

    func testRootPathFallsBackToGenericName() {
        let name = ResponseFileName.suggested(for: response(url: "https://example.com/", headers: [("Content-Type", "text/html")]))
        XCTAssertEqual(name, "response.html")
    }

    func testMissingURLFallsBackToGenericName() {
        XCTAssertEqual(ResponseFileName.suggested(for: response(url: nil)), "response.txt")
    }

    func testVersionSegmentIsNotTreatedAsExtension() {
        let name = ResponseFileName.suggested(for: response(url: "https://api.example.com/v1.2", headers: [("Content-Type", "application/json")]))
        XCTAssertEqual(name, "v1.2.json")
    }

    // MARK: - Uzantı

    func testStructuredSuffixesMapToBaseFormat() {
        XCTAssertEqual(ResponseFileName.fileExtension(contentType: "application/problem+json", body: Data()), "json")
        XCTAssertEqual(ResponseFileName.fileExtension(contentType: "application/atom+xml", body: Data()), "xml")
    }

    func testUnknownTypeFallsBackByBodyKind() {
        XCTAssertEqual(ResponseFileName.fileExtension(contentType: nil, body: Data("merhaba".utf8)), "txt")
        XCTAssertEqual(ResponseFileName.fileExtension(contentType: nil, body: Data([0xFF, 0xFE, 0x00, 0xC3])), "bin")
    }

    // MARK: - Güvenilmez adlar

    func testPathTraversalInDispositionIsNeutralised() {
        let name = ResponseFileName.suggested(for: response(headers: [
            ("Content-Disposition", "attachment; filename=\"../../.ssh/authorized_keys\""),
        ]))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.hasPrefix("."))
    }

    func testBidiOverrideAndControlCharactersAreRemoved() {
        // U+202E ile "fdp.exe" ekranda "exe.pdf" gibi görünür.
        let spoofed = "fatura\u{202E}fdp.exe\u{0007}"
        XCTAssertEqual(ResponseFileName.sanitize(spoofed), "faturafdp.exe")
    }

    func testHiddenAndDotOnlyNamesAreRejected() {
        XCTAssertEqual(ResponseFileName.sanitize(".env"), "env")
        XCTAssertEqual(ResponseFileName.sanitize(".."), "")
        let name = ResponseFileName.suggested(for: response(headers: [
            ("Content-Type", "text/plain"),
            ("Content-Disposition", "attachment; filename=\"..\""),
        ]))
        XCTAssertEqual(name, "users.txt")
    }

    func testLongNameIsCutButKeepsExtension() {
        let long = String(repeating: "a", count: 300) + ".json"
        let name = ResponseFileName.limitLength(long)
        XCTAssertEqual(name.count, ResponseFileName.maxLength)
        XCTAssertTrue(name.hasSuffix(".json"))
    }
}
