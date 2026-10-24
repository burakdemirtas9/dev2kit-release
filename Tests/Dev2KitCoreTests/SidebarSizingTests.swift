import XCTest
@testable import Dev2KitCore

final class SidebarSizingTests: XCTestCase {
    func testMinimumFollowsMeasuredLogoEdgeButNeverBelowBase() {
        XCTAssertEqual(SidebarSizing.minimumWidth(logoTrailingEdge: 206.4, logoWidth: 126.5), 223)
        XCTAssertEqual(SidebarSizing.minimumWidth(logoTrailingEdge: 150, logoWidth: 126.5), 220, "taban korunur")
        XCTAssertEqual(SidebarSizing.minimumWidth(logoTrailingEdge: 260, logoWidth: 126.5), 276)
    }

    func testUnmeasuredOrBrokenEdgeUsesEstimate() {
        let estimate = SidebarSizing.minimumWidth(logoTrailingEdge: nil, logoWidth: 126.5)
        XCTAssertEqual(estimate, (96 + 126.5 + 16).rounded(.up), "macOS 27 ölçümüne yakın (239)")
        XCTAssertEqual(SidebarSizing.minimumWidth(logoTrailingEdge: .nan, logoWidth: 126.5), estimate)
        XCTAssertEqual(SidebarSizing.minimumWidth(logoTrailingEdge: 0, logoWidth: 126.5), estimate)
    }

    func testDraggingCannotGoBelowMinimumOrAboveMaximum() {
        let minimum: CGFloat = 223
        let upper = SidebarSizing.upperBound(contentMaximum: 400, totalWidth: 1400, divider: 1)
        XCTAssertEqual(upper, 400, "en uzun ad kuralı korunur")
        XCTAssertEqual(SidebarSizing.width(preferred: 150, minimum: minimum, upper: upper), minimum)
        XCTAssertEqual(SidebarSizing.width(preferred: 900, minimum: minimum, upper: upper), 400)
        XCTAssertEqual(SidebarSizing.width(preferred: 300, minimum: minimum, upper: upper), 300)
    }

    func testNarrowWindowKeepsMinimumAndLeavesDetailArea() {
        // En küçük pencerede (1140) detaya 480'den fazlası kalır.
        let atMinimumWindow = SidebarSizing.upperBound(contentMaximum: 2000, totalWidth: 1140, divider: 1)
        XCTAssertEqual(atMinimumWindow, 659)
        // Çelişki (üst < asgari): asgari kazanır, logo sıkışmaz.
        let conflicting = SidebarSizing.upperBound(contentMaximum: 2000, totalWidth: 650, divider: 1)
        XCTAssertEqual(SidebarSizing.width(preferred: 300, minimum: 223, upper: conflicting), 223)
    }

    func testRestoredPreference() {
        XCTAssertEqual(SidebarSizing.restoredPreference(0, minimum: 223), 223, "kayıt yok")
        XCTAssertEqual(SidebarSizing.restoredPreference(220, minimum: 223), 223, "eski asgari altı kayıt sınıra çekilir")
        XCTAssertEqual(SidebarSizing.restoredPreference(310, minimum: 223), 310, "geçerli tercih korunur")
        XCTAssertEqual(SidebarSizing.restoredPreference(.infinity, minimum: 223), 223)
    }
}
