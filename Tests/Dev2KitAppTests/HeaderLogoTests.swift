import AppKit
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

@MainActor
final class HeaderLogoTests: XCTestCase {
    /// İki görünümün görseli 1× ve 2× temsilleriyle, görüntüleme boyutunda
    /// yüklenir (yeniden örnekleme yok, bulanıklaşmaz) ve önbellekten gelir.
    func testLogoLoadsBothScalesForBothAppearances() throws {
        for dark in [false, true] {
            let image = try XCTUnwrap(HeaderLogoImage.image(dark: dark))
            XCTAssertEqual(image.size, HeaderLogo.size)
            let pixelWidths = image.representations.map(\.pixelsWide).sorted()
            XCTAssertEqual(pixelWidths, [126, 253], "1× ve 2×")
            XCTAssertTrue(HeaderLogoImage.image(dark: dark) === image)
        }
    }

    /// Görüntüleme boyutu görselin en-boy oranında (esneme yok).
    func testDisplaySizeKeepsAspectRatio() throws {
        let rep = try XCTUnwrap(HeaderLogoImage.image(dark: true)?.representations.max { $0.pixelsWide < $1.pixelsWide })
        let assetRatio = CGFloat(rep.pixelsWide) / CGFloat(rep.pixelsHigh)
        XCTAssertEqual(HeaderLogo.size.width / HeaderLogo.size.height, assetRatio, accuracy: 0.02)
    }

    /// Panel asgarisi ölçülen logo kenarından; ölçüm değişince seçim ve
    /// sekmeler etkilenmez.
    func testSidebarMinimumFollowsLogoWithoutTouchingSelection() {
        let harness = AppStateHarness(); defer { harness.tearDown() }
        let request = harness.addRequest(named: "seçili")
        let tabs = harness.state.openTabs
        harness.state.headerLogoTrailingEdge = 223
        XCTAssertEqual(harness.state.sidebarMinimumWidth, 239)
        harness.state.headerLogoTrailingEdge = 180   // ör. tam ekranda pencere düğmeleri yok
        XCTAssertEqual(harness.state.sidebarMinimumWidth, 220, "taban")
        XCTAssertEqual(harness.state.selectedRequestID, request.id)
        XCTAssertEqual(harness.state.openTabs, tabs)
    }
}
