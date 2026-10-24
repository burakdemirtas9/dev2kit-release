import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

@MainActor
final class HTTPCatImagesTests: XCTestCase {
    func testEveryMappedCodeLoadsAndIsCached() throws {
        for code in HTTPCats.codes {
            let first = try XCTUnwrap(HTTPCatImages.image(for: code), "\(code) yüklenmeli")
            XCTAssertGreaterThan(first.size.width, 0)
            // İkinci çift tıklama diskten okumaz: aynı nesne.
            XCTAssertTrue(HTTPCatImages.image(for: code) === first)
        }
    }

    func testUnmappedCodeHasNoImage() {
        XCTAssertNil(HTTPCatImages.image(for: 299))
        XCTAssertNil(HTTPCatImages.image(for: 0))
    }
}
