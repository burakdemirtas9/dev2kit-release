import XCTest
@testable import Dev2KitCore

final class MultiSelectionTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private var order: [UUID] { [a, b, c, d] }

    // MARK: - Aktif istek

    func testActiveStaysWhenStillSelected() {
        // ⇧ ile seçim genişledi; detayda açık olan istek değişmemeli.
        XCTAssertEqual(MultiSelection.active(current: b, selection: [a, b, c], order: order), b)
    }

    func testActiveMovesToLastSelectedWhenCurrentDropsOut() {
        XCTAssertEqual(MultiSelection.active(current: d, selection: [a, b], order: order), b)
    }

    func testEmptySelectionKeepsActive() {
        // Filtreleme seçimi boşaltınca açık istek kapanmamalı.
        XCTAssertEqual(MultiSelection.active(current: c, selection: [], order: order), c)
    }

    func testSingleSelectionBecomesActive() {
        XCTAssertEqual(MultiSelection.active(current: nil, selection: [c], order: order), c)
    }

    func testSelectionOutsideOrderStillResolves() {
        let stranger = UUID()
        XCTAssertEqual(MultiSelection.active(current: nil, selection: [stranger], order: order), stranger)
    }

    // MARK: - Temizleme

    func testPrunedDropsMissingIDs() {
        XCTAssertEqual(MultiSelection.pruned([a, b, c], live: [b, c, d]), [b, c])
    }

    // MARK: - Tıklama (List kullanmayan satırlar: Token Factory)

    func testPlainClickSelectsOnlyThatRowAndMovesTheAnchor() {
        let result = MultiSelection.click(c, .plain, selection: [a, b], anchor: a, order: order)
        XCTAssertEqual(result.selection, [c])
        XCTAssertEqual(result.anchor, c)
    }

    func testCommandClickAddsAndRemoves() {
        let added = MultiSelection.click(c, .toggle, selection: [a], anchor: a, order: order)
        XCTAssertEqual(added.selection, [a, c])
        XCTAssertEqual(added.anchor, c)
        let removed = MultiSelection.click(a, .toggle, selection: [a, c], anchor: c, order: order)
        XCTAssertEqual(removed.selection, [c])
    }

    func testShiftClickSelectsTheRangeFromTheAnchorInEitherDirection() {
        XCTAssertEqual(MultiSelection.click(c, .range, selection: [a], anchor: a, order: order).selection, [a, b, c])
        let upward = MultiSelection.click(a, .range, selection: [c], anchor: c, order: order)
        XCTAssertEqual(upward.selection, [a, b, c])
        XCTAssertEqual(upward.anchor, c, "aralıkta çapa sabit kalır")
    }

    func testShiftClickWithoutAnAnchorInTheListActsLikeAPlainClick() {
        let stranger = UUID()
        let result = MultiSelection.click(b, .range, selection: [stranger], anchor: stranger, order: order)
        XCTAssertEqual(result.selection, [b])
        XCTAssertEqual(result.anchor, b)
    }

    // MARK: - Bağlam menüsü hedefi

    func testContextMenuOnSelectedRowTargetsWholeSelection() {
        XCTAssertEqual(MultiSelection.targets(forContextMenuOn: b, selection: [a, b]), [a, b])
    }

    func testContextMenuOutsideSelectionTargetsOnlyThatRow() {
        XCTAssertEqual(MultiSelection.targets(forContextMenuOn: d, selection: [a, b]), [d])
    }
}
