import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı isteği (2026-10-18): araç (biçimlendirici, dönüştürücü, Diff
/// Checker) seçilince ya da sekme değişince imleç girdide yanıp sönsün.
@MainActor
final class WorkbenchFocusTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "workbenchTool")
    }

    private func editors(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }

    func testSelectingAToolOrTabFocusesTheInputEditor() throws {
        let state = WorkbenchState()
        state.select(toolID: "json")
        let host = NSHostingView(rootView: WorkbenchView().environment(state).frame(width: 1000, height: 500))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1000, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        settle()

        func focusedEditor() -> NSTextView? { window.firstResponder as? NSTextView }
        func inputEditor() -> NSTextView? { editors(host).first { $0.isEditable } }

        XCTAssertNotNil(focusedEditor(), "Workbench açılınca girdi odakta")
        XCTAssertTrue(focusedEditor() === inputEditor())

        window.makeFirstResponder(nil)
        state.select(toolID: "xml")
        settle()
        XCTAssertTrue(focusedEditor() === inputEditor(), "araç değişince girdi odakta")

        // Sekmeler yalnızca JSON'da: yeni sekme JSON aracında açılır.
        state.select(toolID: "json")
        settle()
        window.makeFirstResponder(nil)
        state.newDocument()
        settle()
        XCTAssertTrue(focusedEditor() === inputEditor(), "yeni sekmede girdi odakta")

        window.makeFirstResponder(nil)
        state.select(toolID: WorkbenchCatalog.diffCheckerID)
        settle()
        let left = editors(host).filter(\.isEditable).min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        XCTAssertNotNil(focusedEditor())
        XCTAssertTrue(focusedEditor() === left, "Diff Checker'da sol taraf odakta")
    }

    func testEveryToolAndDiffLanguageHasASample() {
        for tool in WorkbenchCatalog.all {
            XCTAssertFalse(tool.sampleInput.isEmpty, tool.id)
            // Örnek aracın kendi girdisi olarak geçerli olmalı: kullanıcı onu yazarsa çalışsın.
            if let validate = tool.validate {
                if case .invalid(let issue) = validate(tool.sampleInput) { XCTFail("\(tool.id): \(issue.message)") }
            }
            XCTAssertNoThrow(try tool.actions[0].run(tool.sampleInput, tool.defaultOptions), tool.id)
        }
        for language in DiffChecker.Language.allCases {
            XCTAssertNotEqual(language.samples.left, language.samples.right, language.rawValue)
        }
    }
}
