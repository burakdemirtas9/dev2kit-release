import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı bildirimi (2026-10-21, ekran kaydı): API Client'ta Gönder
/// düğmesinde ve istek alanının boş yerlerinde I-beam. Çalışan uygulamada
/// ölçüldü: imleç alanları Workbench'in görünmeyen editörlerine aitti
/// (gizli mod yalnızca `opacity(0)`, AppKit'te `alphaValue = 0`; AppKit
/// saydam görünümün cursor rect'ini çalıştırmaya devam ediyor).
@MainActor
final class HiddenModeCursorTests: XCTestCase {
    private var harness: AppStateHarness!

    override func setUp() { harness = AppStateHarness() }
    override func tearDown() {
        harness.tearDown()
        UserDefaults.standard.removeObject(forKey: "appMode")
        UserDefaults.standard.removeObject(forKey: "workbenchTool")
    }

    private func settle(_ seconds: TimeInterval = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Görünmeyen ama AppKit'te etkin (imleç alanı çalışan) imleç sahipleri.
    private func leakingOwners(_ root: NSView) -> [NSView] {
        HiddenModeCursorGuard.cursorOwners(in: root).filter { HiddenModeCursorGuard.isTransparent($0) }
    }

    private func visibleOwners(_ root: NSView) -> [NSView] {
        HiddenModeCursorGuard.cursorOwners(in: root).filter { !HiddenModeCursorGuard.isTransparent($0) }
    }

    func testHiddenModeTextViewsDoNotKeepCursorAreas() throws {
        harness.addRequest(named: "R", url: "https://api.example.com/users")
        harness.state.mode = .apiClient
        let workbench = WorkbenchState()
        let controller = NSHostingController(rootView: ContentView().environment(harness.state).environment(workbench))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1140, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        settle()

        // İki modu da canlı kur (açılıştaki ön kurulum ve geçişlerle aynı yol).
        harness.state.mode = .workbench
        settle()
        harness.state.mode = .apiClient
        settle()

        func editors(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(editors) }
        let all = editors(root)
        XCTAssertTrue(all.contains { $0 is AddressTextView }, "API Client adres alanı")
        XCTAssertTrue(all.contains { !($0 is AddressTextView) && HiddenModeCursorGuard.isTransparent($0) },
                      "gizli Workbench'in editörleri canlı (ağaç korunuyor)")

        XCTAssertEqual(leakingOwners(root), [], "API Client'ta Workbench'in görünmeyen alanları imleci almamalı")
        let address = try XCTUnwrap(all.first { $0 is AddressTextView })
        XCTAssertFalse(address.isHiddenOrHasHiddenAncestor, "görünür adres alanı etkin kalır")

        harness.state.mode = .workbench
        settle()
        XCTAssertEqual(leakingOwners(root), [], "Workbench'te API Client'ın görünmeyen alanları imleci almamalı")
        XCTAssertTrue(address.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(visibleOwners(root).isEmpty, "Workbench editörleri etkin")
        XCTAssertTrue(visibleOwners(root).allSatisfy { !$0.isHiddenOrHasHiddenAncestor })

        harness.state.mode = .apiClient
        settle()
        XCTAssertFalse(address.isHiddenOrHasHiddenAncestor, "mod geri gelince alan yeniden etkin")
        XCTAssertEqual(address.string, "https://api.example.com/users", "metin korunur")
        XCTAssertEqual(leakingOwners(root), [])
    }

    /// Saydam düğmeler (⌘K'nın görünmez düğmesi) gizlenmez: kısayolları çalışır.
    func testOnlyTextOwnersAreAffected() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let button = NSButton(title: "", target: nil, action: nil)
        let label = NSTextField(labelWithString: "etiket")
        let field = NSTextField(string: "alan")
        [button, label, field].forEach(container.addSubview)
        container.alphaValue = 0
        HiddenModeCursorGuard.sync(container)
        XCTAssertFalse(button.isHidden)
        XCTAssertFalse(label.isHidden, "seçilemeyen etiket I-beam koymaz")
        XCTAssertTrue(field.isHidden)
        container.alphaValue = 1
        HiddenModeCursorGuard.sync(container)
        XCTAssertFalse(field.isHidden)
    }
}
