import XCTest
@testable import Dev2KitCore

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
        tabs.keep(a)
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

    // MARK: - Sabitleme (2026-10-31, Chrome / VS Code kuralları)

    func testPinnedTabsComeFirstInPinOrder() {
        var tabs = RequestTabs(tabs: [a, b, c, d])
        tabs.pin(c)
        tabs.pin(a)
        XCTAssertEqual(tabs.tabs, [c, a, b, d], "sabitler başta, sabitlenme sırasıyla")
        XCTAssertEqual(tabs.pinned, [c, a])
        tabs.pin(c)
        XCTAssertEqual(tabs.tabs, [c, a, b, d], "yeniden sabitlemek sırayı değiştirmez")
    }

    func testUnpinnedTabMovesToTheStartOfUnpinned() {
        var tabs = RequestTabs(tabs: [a, b, c])
        tabs.pin(b)
        tabs.pin(c)            // [b, c, a]
        tabs.unpin(b)
        XCTAssertEqual(tabs.tabs, [c, b, a])
        XCTAssertEqual(tabs.pinned, [c])
        tabs.unpin(d)
        XCTAssertEqual(tabs.tabs, [c, b, a], "sabit olmayan: değişmez")
    }

    func testPinningThePreviewKeepsIt() {
        var tabs = RequestTabs(tabs: [a])
        tabs.open(b)
        tabs.pin(b)
        XCTAssertNil(tabs.preview, "sabitlenen önizleme kalıcı olur")
        XCTAssertEqual(tabs.tabs, [b, a])
        XCTAssertEqual(tabs.permanent, [b, a])
    }

    func testPinningAClosedTabOpensIt() {
        var tabs = RequestTabs(tabs: [a])
        tabs.pin(b)
        XCTAssertEqual(tabs.tabs, [b, a])
        XCTAssertEqual(tabs.pinned, [b])
    }

    func testPreviewNeverLandsAmongPinned() {
        var tabs = RequestTabs(tabs: [a, b])
        tabs.pin(a)
        tabs.open(c)           // önizleme: [a | b, c*]
        tabs.open(d)           // önizlemenin yerine
        XCTAssertEqual(tabs.tabs, [a, b, d])
        XCTAssertEqual(tabs.preview, d)
        XCTAssertFalse(tabs.isPinned(d))
    }

    func testMoveStaysWithinItsGroup() {
        var tabs = RequestTabs(tabs: [a, b, c, d])
        tabs.pin(a)
        tabs.pin(b)            // [a, b | c, d]
        tabs.move(c, before: a)
        XCTAssertEqual(tabs.tabs, [a, b, c, d], "sabit olmayan sabitlerin arasına giremez")
        tabs.move(a, before: d)
        XCTAssertEqual(tabs.tabs, [a, b, c, d], "sabit, sabit olmayanların arasına giremez")
        tabs.move(b, before: a)
        XCTAssertEqual(tabs.tabs, [b, a, c, d])
        XCTAssertEqual(tabs.pinned, [b, a], "sabit sırası da değişir")
        tabs.move(d, before: c)
        XCTAssertEqual(tabs.tabs, [b, a, d, c])
    }

    func testCloseOthersAndToTheRightSparePinned() {
        var tabs = RequestTabs(tabs: [a, b, c, d])
        tabs.pin(a)            // [a | b, c, d]
        XCTAssertEqual(tabs.closeToRight(of: a, selected: d), a)
        XCTAssertEqual(tabs.tabs, [a], "sağdakiler kapanır")

        var others = RequestTabs(tabs: [a, b, c, d])
        others.pin(d)          // [d | a, b, c]
        XCTAssertEqual(others.closeOthers(keeping: b), b)
        XCTAssertEqual(others.tabs, [d, b], "sabit kalır")
    }

    func testClosingAPinnedTabUnpinsIt() {
        var tabs = RequestTabs(tabs: [a, b])
        tabs.pin(b)            // [b | a]
        XCTAssertEqual(tabs.close(b, selected: b), a, "⌘W sabiti de kapatır")
        XCTAssertEqual(tabs.pinned, [])
        tabs.keep(b)
        XCTAssertFalse(tabs.isPinned(b), "yeniden açılınca sabit değildir")

        var pruned = RequestTabs(tabs: [a, b, c])
        pruned.pin(c)
        _ = pruned.prune(keeping: [a, b], selected: a)
        XCTAssertEqual(pruned.pinned, [], "silinen istek sabitlerden düşer")
    }

    // MARK: - Sürükleyerek sıralama (2026-10-31)

    /// Sekmeler 100 genişliğinde: a 0–100 (orta 50), b 100–200 (150), c 200–300 (250), d (350).
    private var mids: [UUID: Double] { [a: 50, b: 150, c: 250, d: 350] }

    func testDragSwapsOnlyAfterPassingTheNeighboursMiddle() {
        let tabs = RequestTabs(tabs: [a, b, c, d])
        XCTAssertNil(tabs.reorderTarget(for: a, center: 140, midX: mids), "b'nin ortasına varmadı")
        XCTAssertEqual(tabs.reorderTarget(for: a, center: 151, midX: mids), b)
        XCTAssertEqual(tabs.reorderTarget(for: d, center: 249, midX: mids), c, "sola doğru")
        XCTAssertNil(tabs.reorderTarget(for: b, center: 150, midX: mids), "kendi yerinde")
    }

    func testFastDragSkipsSeveralTabs() {
        var tabs = RequestTabs(tabs: [a, b, c, d])
        let target = tabs.reorderTarget(for: a, center: 300, midX: mids)
        XCTAssertEqual(target, c)
        tabs.move(a, before: try! XCTUnwrap(target))
        XCTAssertEqual(tabs.tabs, [b, c, a, d])
        XCTAssertEqual(RequestTabs(tabs: [a, b, c, d]).reorderTarget(for: d, center: 10, midX: mids), a)
    }

    func testDragDoesNotCrossThePinnedBoundary() {
        var tabs = RequestTabs(tabs: [a, b, c, d])
        tabs.pin(a)
        tabs.pin(b)            // [a, b | c, d]
        XCTAssertNil(tabs.reorderTarget(for: c, center: 20, midX: mids), "sabitlerin arasına girmez")
        XCTAssertNil(tabs.reorderTarget(for: b, center: 380, midX: mids), "sabit olmayanlara geçmez")
        XCTAssertEqual(tabs.reorderTarget(for: b, center: 40, midX: mids), a)
    }

    func testRestoredStateIsNormalized() {
        let tabs = RequestTabs(tabs: [a, b, c, b], preview: c, pinned: [c, d, c])
        XCTAssertEqual(tabs.tabs, [c, a, b], "tekrar atılır, sabit başa, açık olmayan sabit düşer")
        XCTAssertEqual(tabs.pinned, [c])
        XCTAssertNil(tabs.preview, "sabit önizleme olamaz")
    }
}
