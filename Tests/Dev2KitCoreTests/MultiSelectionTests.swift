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

    // MARK: - Bağlam menüsü hedefi

    func testContextMenuOnSelectedRowTargetsWholeSelection() {
        XCTAssertEqual(MultiSelection.targets(forContextMenuOn: b, selection: [a, b]), [a, b])
    }

    func testContextMenuOutsideSelectionTargetsOnlyThatRow() {
        XCTAssertEqual(MultiSelection.targets(forContextMenuOn: d, selection: [a, b]), [d])
    }
}
