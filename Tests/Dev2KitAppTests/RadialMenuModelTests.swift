import XCTest
import SwiftUI
import AppKit
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Dairesel menünün zamanlaması: sıra, yön değişimi, hızlı tekrar ve iptal.
/// Animasyon tamamlanması gerçek bir çizim döngüsü ister; menü ekran
/// dışındaki bir pencerede çizilir (kullanıcının ekranına dokunulmaz).
@MainActor
final class RadialMenuModelTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func host(_ model: RadialMenuModel, count: Int = 6, style: RadialMenuStyle) {
        let items = (1..<count).map { index in
            RadialMenuItem(id: "\(index)", title: "\(index)", closesMenu: false, icon: AnyView(Image(systemName: "circle")), action: {})
        }
        let view = RadialMenuView(model: model, items: items, style: style, triggerTitle: "S", closeTitle: "C",
                                  triggerIcon: "gearshape", closeIcon: "xmark")
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        self.window = window
        model.prepare(count: count)
    }

    private func wait(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func settle(_ model: RadialMenuModel, until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private let fast = RadialMenuStyle(stagger: .milliseconds(30), springResponse: 0.12, springDamping: 1)
    private var timing: RadialMenuTiming { RadialMenuTiming(style: fast, reduceMotion: false) }

    func testOpensItemByItemClockwiseAndSettlesOpen() async {
        let model = RadialMenuModel()
        host(model, style: fast)
        model.open(RadialMenuTiming(style: RadialMenuStyle(stagger: .milliseconds(150), springResponse: 0.12, springDamping: 1), reduceMotion: false))
        XCTAssertEqual(model.phase, .opening)
        XCTAssertEqual(model.progress, [1, 1, 0, 0, 0, 0], "yalnızca ilk öğe hemen başlar")
        await wait(0.2)
        XCTAssertEqual(model.progress[2], 1)
        XCTAssertEqual(model.progress[5], 0, "sonraki öğeler sırasını bekler")
        await settle(model) { model.phase == .open }
        XCTAssertEqual(model.phase, .open)
        XCTAssertEqual(model.progress, [1, 1, 1, 1, 1, 1])
    }

    func testClosesInReverseOrderAndReportsFullyClosedOnce() async {
        let model = RadialMenuModel()
        host(model, style: fast)
        var closedCount = 0
        model.onFullyClosed = { closedCount += 1 }
        model.open(timing)
        await settle(model) { model.phase == .open }
        model.close(RadialMenuTiming(style: RadialMenuStyle(stagger: .milliseconds(150), springResponse: 0.12, springDamping: 1), reduceMotion: false))
        XCTAssertEqual(model.progress, [1, 1, 1, 1, 1, 0], "son açılan ilk kapanır")
        await settle(model) { model.phase == .closed }
        XCTAssertEqual(model.progress, [1, 0, 0, 0, 0, 0])
        XCTAssertEqual(closedCount, 1)
    }

    /// Açılırken kapat: başlamamış öğeler hiç açılmaz, eski açılma görevi
    /// kapanıştan sonra çalışıp öğeleri geri getirmez.
    func testClosingMidOpenCancelsPendingSteps() async {
        let model = RadialMenuModel()
        host(model, style: fast)
        model.open(RadialMenuTiming(style: RadialMenuStyle(stagger: .milliseconds(120), springResponse: 0.12, springDamping: 1), reduceMotion: false))
        await wait(0.05)
        model.close(timing)
        XCTAssertEqual(model.phase, .closing)
        await settle(model) { model.phase == .closed }
        await wait(0.6) // eski gecikmeler dolsa bile
        XCTAssertEqual(model.phase, .closed)
        XCTAssertEqual(model.progress, [1, 0, 0, 0, 0, 0])
    }

    /// Kapanırken yeniden aç: yön değişir, menü açık biter.
    func testReopeningMidCloseEndsOpen() async {
        let model = RadialMenuModel()
        host(model, style: fast)
        model.open(timing)
        await settle(model) { model.phase == .open }
        model.close(timing)
        await wait(0.04)
        model.open(timing)
        await settle(model) { model.phase == .open }
        XCTAssertEqual(model.phase, .open)
        XCTAssertEqual(model.progress, [1, 1, 1, 1, 1, 1])
    }

    func testRapidTogglesStayConsistent() async {
        let model = RadialMenuModel()
        host(model, style: fast)
        var closedCount = 0
        model.onFullyClosed = { closedCount += 1 }
        for _ in 0..<7 {
            model.toggle(timing)
            await wait(0.015)
        }
        // 7 tıklama: son hedef açık.
        XCTAssertTrue(model.isExpanded)
        await settle(model) { model.phase == .open }
        XCTAssertEqual(model.progress, [1, 1, 1, 1, 1, 1])
        model.toggle(timing)
        await settle(model) { model.phase == .closed }
        XCTAssertEqual(model.progress, [1, 0, 0, 0, 0, 0])
        XCTAssertLessThanOrEqual(closedCount, 1, "ara kapanışlar 'tamamen kapandı' saymaz")
    }

    func testResetClosesImmediatelyWithoutAnimation() async {
        let model = RadialMenuModel()
        host(model, style: fast)
        var closed = false
        model.onFullyClosed = { closed = true }
        model.open(timing)
        await wait(0.04)
        model.reset()
        XCTAssertEqual(model.phase, .closed)
        XCTAssertTrue(closed)
        await wait(0.3)
        XCTAssertEqual(model.progress, [1, 0, 0, 0, 0, 0], "iptal edilen görev öğe açmaz")
    }
}

/// Yarıçap öğe sayısına göre büyür; menü pencere içinde kalır.
final class RadialMenuGeometryTests: XCTestCase {
    func testRadiusGrowsSoEightItemsDoNotCollide() {
        let style = RadialMenuStyle()
        XCTAssertEqual(style.effectiveRadius(count: 6), style.radius, "6 öğe varsayılan yarıçapa sığar")
        let radius = style.effectiveRadius(count: 8)
        XCTAssertGreaterThanOrEqual(radius, style.radius)
        let gap = RadialMenuLayout(count: 8, radius: Double(radius)).gap(itemDiameter: Double(style.itemDiameter))
        XCTAssertGreaterThanOrEqual(gap, Double(style.minimumGap) - 0.001)
    }

    /// Ölçülen yer (900 pt pencere, kısa environment adı): çark merkezi
    /// x = 738.5. Sekiz öğeli menü pencereden taşmaz, kaydırma gerekmez
    /// (kapatma çarkla hizalı).
    @MainActor
    func testMenuFitsInsideTheWindowFromTheGear() {
        let style = RadialMenuStyle()
        let canvas = RadialMenuView.canvas(count: 8, style: style)
        let window = NSRect(x: 0, y: 0, width: 900, height: 600)
        let gear = CGPoint(x: 738.5, y: 600 - 26)
        let frame = NSRect(x: gear.x - canvas.anchor.x, y: gear.y + canvas.anchor.y - canvas.size.height,
                           width: canvas.size.width, height: canvas.size.height)
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, 900)
        XCTAssertEqual(RadialMenuPanel.clamped(frame, inside: window, screen: nil), frame)
    }

    @MainActor
    func testClampKeepsTheMenuInsideWhenItWouldOverflow() {
        let frame = NSRect(x: -30, y: 500, width: 160, height: 150)
        let clamped = RadialMenuPanel.clamped(frame, inside: NSRect(x: 0, y: 0, width: 900, height: 600), screen: nil)
        XCTAssertEqual(clamped.minX, 0)
        XCTAssertEqual(clamped.maxY, 600)
    }
}

/// Klavye odağı: saat yönünde ilerler, uçlarda döner, kapanınca silinir.
@MainActor
final class RadialMenuFocusTests: XCTestCase {
    private func openModel(count: Int) -> RadialMenuModel {
        let model = RadialMenuModel()
        model.prepare(count: count)
        model.open(RadialMenuTiming(style: RadialMenuStyle(), reduceMotion: true))
        return model
    }

    func testNoFocusUntilAKeyIsUsed() {
        XCTAssertNil(openModel(count: 6).focusedIndex, "fareyle açınca odak halkası yok")
    }

    func testForwardStartsAtTheFirstItemAndWraps() {
        let model = openModel(count: 4)
        model.moveFocus(by: 1)
        XCTAssertEqual(model.focusedIndex, 1)
        model.moveFocus(by: 1); model.moveFocus(by: 1)
        XCTAssertEqual(model.focusedIndex, 3)
        model.moveFocus(by: 1)
        XCTAssertEqual(model.focusedIndex, 0, "son öğeden tetikleyiciye döner")
    }

    func testBackwardStartsAtTheLastItemAndWraps() {
        let model = openModel(count: 4)
        model.moveFocus(by: -1)
        XCTAssertEqual(model.focusedIndex, 3)
        model.moveFocus(by: -1); model.moveFocus(by: -1); model.moveFocus(by: -1)
        XCTAssertEqual(model.focusedIndex, 0)
        model.moveFocus(by: -1)
        XCTAssertEqual(model.focusedIndex, 3)
    }

    func testClosingClearsFocusAndAClosedMenuIgnoresKeys() {
        let model = openModel(count: 4)
        model.moveFocus(by: 1)
        model.reset()
        XCTAssertNil(model.focusedIndex)
        model.moveFocus(by: 1)
        XCTAssertNil(model.focusedIndex, "kapalı menüde odak yok")
    }
}

/// 2026-10-20 hatası: kapanırken ikinci kapatma (dışarı tıklama) menüyü
/// kapanışta takılı bırakıyordu.
@MainActor
final class RadialMenuInterruptTests: XCTestCase {
    func testSecondCloseWhileClosingStillFinishes() async {
        let model = RadialMenuModel()
        let items = (1..<6).map { RadialMenuItem(id: "\($0)", title: "\($0)", closesMenu: false, icon: AnyView(Image(systemName: "circle")), action: {}) }
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RadialMenuView(model: model, items: items, style: RadialMenuStyle(), triggerTitle: "S", closeTitle: "C", triggerIcon: "gearshape", closeIcon: "xmark"))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        model.prepare(count: 6)
        let timing = RadialMenuTiming(style: RadialMenuStyle(stagger: .milliseconds(30), springResponse: 0.15, springDamping: 1), reduceMotion: false)
        var closed = 0
        model.onFullyClosed = { closed += 1 }
        model.open(timing)
        for _ in 0..<200 where model.phase != .open { try? await Task.sleep(for: .milliseconds(10)) }
        model.close(timing)
        try? await Task.sleep(for: .milliseconds(60))
        model.close(timing) // kapanırken dışarı tıklama
        model.close(timing)
        for _ in 0..<300 where model.phase != .closed { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.phase, .closed, "kapanış takılmamalı")
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(model.progress, [1, 0, 0, 0, 0, 0])
    }

    func testSecondOpenWhileOpeningDoesNotRestart() {
        let model = RadialMenuModel()
        model.prepare(count: 6)
        let timing = RadialMenuTiming(style: RadialMenuStyle(), reduceMotion: true)
        model.open(timing)
        let progress = model.progress
        model.open(timing)
        XCTAssertEqual(model.progress, progress)
        XCTAssertEqual(model.phase, .opening)
    }
}
