import XCTest
@testable import SecoraCore

final class RequestTabsTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testOpeningReplacesThePreviewTab() {
        var tabs = RequestTabs()
        tabs.open(a)
        tabs.open(b)
        XCTAssertEqual(tabs.tabs, [b], "önizleme yerine yenisi gelmeli")
        XCTAssertEqual(tabs.preview, b)
    }

    func testUsedTabBecomesPermanentAndNextOpensBesideIt() {
        var tabs = RequestTabs()
        tabs.open(a)
        tabs.pin(a)
        tabs.open(b)
        tabs.open(c)
        XCTAssertEqual(tabs.tabs, [a, c])
        XCTAssertEqual(tabs.permanent, [a])
    }

    func testPreviewKeepsItsPositionWhenReplaced() {
        var tabs = RequestTabs(tabs: [a, b])
        tabs.open(c)          // [a, b, c*]
        tabs.move(c, before: a) // [c*, a, b]
        tabs.open(d)
        XCTAssertEqual(tabs.tabs, [d, a, b])
    }

    func testOpeningAnAlreadyOpenTabChangesNothing() {
        var tabs = RequestTabs(tabs: [a, b])
        tabs.open(c)
        tabs.open(a)
        XCTAssertEqual(tabs.tabs, [a, b, c])
        XCTAssertEqual(tabs.preview, c)
    }

    func testClosingSelectedTabSelectsRightThenLeft() {
        var tabs = RequestTabs(tabs: [a, b, c])
        XCTAssertEqual(tabs.close(b, selected: b), c)
        XCTAssertEqual(tabs.close(c, selected: c), a)
        XCTAssertNil(tabs.close(a, selected: a))
    }

    func testClosingAnotherTabKeepsSelection() {
        var tabs = RequestTabs(tabs: [a, b, c])
        XCTAssertEqual(tabs.close(a, selected: c), c)
        XCTAssertEqual(tabs.tabs, [b, c])
    }

    func testCloseOthersAndToTheRight() {
        var tabs = RequestTabs(tabs: [a, b, c, d])
        XCTAssertEqual(tabs.closeToRight(of: b, selected: d), b, "seçili sekme kapandıysa referans sekme seçilir")
        XCTAssertEqual(tabs.tabs, [a, b])
        XCTAssertEqual(tabs.closeOthers(keeping: a), a)
        XCTAssertEqual(tabs.tabs, [a])
    }

    func testMoveInBothDirections() {
        var tabs = RequestTabs(tabs: [a, b, c])
        tabs.move(a, before: c)
        XCTAssertEqual(tabs.tabs, [b, c, a])
        tabs.move(a, before: b)
        XCTAssertEqual(tabs.tabs, [a, b, c])
    }

    func testAdjacentWrapsAround() {
        let tabs = RequestTabs(tabs: [a, b, c])
        XCTAssertEqual(tabs.adjacent(to: c, offset: 1), a)
        XCTAssertEqual(tabs.adjacent(to: a, offset: -1), c)
        XCTAssertNil(RequestTabs().adjacent(to: nil, offset: 1))
    }

    func testPruneClosesDeletedRequestsAndMovesSelection() {
        var tabs = RequestTabs(tabs: [a, b, c])
        XCTAssertEqual(tabs.prune(keeping: [a, c], selected: b), c)
        XCTAssertEqual(tabs.tabs, [a, c])
    }

    func testPreviewIsNotPersisted() {
        var tabs = RequestTabs(tabs: [a])
        tabs.open(b)
        XCTAssertEqual(tabs.permanent, [a])
    }
}
