import XCTest
@testable import Dev2KitCore

final class AppPathsTests: XCTestCase {
    func testDefaultIsUnderApplicationSupport() {
        let url = AppPaths.directory(environment: [:])
        XCTAssertEqual(url.lastPathComponent, "dev2kit")
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    func testEnvironmentOverrideWins() {
        let url = AppPaths.directory(environment: [AppPaths.directoryEnvironmentKey: "/tmp/dev2kit-deneme"])
        XCTAssertEqual(url.path, "/tmp/dev2kit-deneme")
    }

    func testTildeIsExpanded() {
        let url = AppPaths.directory(environment: [AppPaths.directoryEnvironmentKey: "~/dev2kit-deneme"])
        XCTAssertFalse(url.path.hasPrefix("~"))
        XCTAssertTrue(url.path.hasSuffix("dev2kit-deneme"))
    }

    func testBlankOverrideIsIgnored() {
        // Boş değişken "varsayılanı kullan" demektir; boş yola yazmak veri kaybı olurdu.
        let url = AppPaths.directory(environment: [AppPaths.directoryEnvironmentKey: "   "])
        XCTAssertTrue(url.path.contains("Application Support"))
    }
}
