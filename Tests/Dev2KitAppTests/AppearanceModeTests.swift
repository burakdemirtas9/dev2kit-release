import XCTest
@testable import Dev2KitApp

/// Ayarlar menüsündeki tema düğmesi: tıklama Koyu ↔ Açık, sistemdeyken
/// görünenin tersi.
final class AppearanceModeTests: XCTestCase {
    func testClickTogglesBetweenDarkAndLight() {
        XCTAssertEqual(AppearanceMode.dark.toggled(systemIsDark: true), .light)
        XCTAssertEqual(AppearanceMode.light.toggled(systemIsDark: true), .dark)
        XCTAssertEqual(AppearanceMode.dark.toggled(systemIsDark: false), .light)
    }

    func testFromSystemTheClickAlwaysChangesWhatIsOnScreen() {
        XCTAssertEqual(AppearanceMode.system.toggled(systemIsDark: true), .light)
        XCTAssertEqual(AppearanceMode.system.toggled(systemIsDark: false), .dark)
    }
}
