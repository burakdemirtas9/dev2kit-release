import XCTest
@testable import Dev2KitCore

final class HTTPStatusTests: XCTestCase {
    private var catsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Dev2KitApp/Resources/HTTPCats")
    }

    /// Eşleme klasördeki dosyalarla birebir: listede olup dosyası olmayan
    /// (boş görsel) ya da dosyası olup listede olmayan kod yok.
    func testCatCodesMatchResourceFilesExactly() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: catsDirectory.path)
            .filter { $0.hasSuffix(".png") }
        let fileCodes = Set(files.compactMap { name -> Int? in
            guard name.hasPrefix("http-cat-") else { return nil }
            return Int(name.dropFirst("http-cat-".count).dropLast(".png".count))
        })
        XCTAssertEqual(fileCodes, HTTPCats.codes)
        XCTAssertEqual(files.count, HTTPCats.codes.count, "adı kurala uymayan dosya var: \(files)")
    }

    func testResourceNameOnlyForKnownCodes() {
        XCTAssertEqual(HTTPCats.resourceName(for: 418), "http-cat-418")
        XCTAssertNil(HTTPCats.resourceName(for: 299))
        XCTAssertNil(HTTPCats.resourceName(for: 0), "status'u bilinmeyen örnekte görsel yok")
    }

    /// Görseller küçük kalsın (rozet ~28 pt); büyük kaynak paketi şişirmesin.
    func testCatImagesAreOptimized() throws {
        for code in HTTPCats.codes {
            let url = catsDirectory.appendingPathComponent("http-cat-\(code).png")
            let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            XCTAssertLessThan(size, 40_000, "\(code): \(size) bayt")
        }
    }

    func testSummary() {
        XCTAssertEqual(HTTPStatus.summary(404), "404 Not Found")
        XCTAssertEqual(HTTPStatus.summary(418), "418 I'm a teapot")
        XCTAssertEqual(HTTPStatus.summary(299), "299")
    }
}
