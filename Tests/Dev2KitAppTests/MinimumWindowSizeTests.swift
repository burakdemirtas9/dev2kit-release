import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı bildirimi (2026-10-21): pencere en küçük haline getirilince
/// Workbench'te düğmeler görünmüyordu. Asgari pencere genişliği, her aracın
/// her eyleminde iki dilde de içeriğin istediği genişliği karşılamalı.
@MainActor
final class MinimumWindowSizeTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "workbenchTool")
    }

    private func widestWorkbench(in language: AppLanguage) -> (width: CGFloat, name: String) {
        var widest: (width: CGFloat, name: String) = (0, "")
        withLanguage(language) {
            let harness = AppStateHarness()
            defer { harness.tearDown() }
            harness.state.mode = .workbench
            let workbench = WorkbenchState()
            let controller = NSHostingController(rootView: ContentView().environment(harness.state).environment(workbench))
            controller.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1400, height: 700),
                                  styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for tool in WorkbenchCatalog.all {
                for action in tool.actions {
                    workbench.select(toolID: tool.id)
                    workbench.select(actionID: action.id)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    let width = controller.view.fittingSize.width
                    if width > widest.width { widest = (width, "\(tool.id)/\(action.id)") }
                }
            }
        }
        return widest
    }

    func testEveryWorkbenchToolFitsTheMinimumWindowWidth() {
        for language in [AppLanguage.turkish, .english] {
            let widest = widestWorkbench(in: language)
            XCTAssertGreaterThan(widest.width, 0)
            XCTAssertLessThanOrEqual(widest.width, Dev2KitApp.minimumWindowSize.width,
                                     "\(language): \(widest.name) \(widest.width) punto istiyor")
        }
    }
}
