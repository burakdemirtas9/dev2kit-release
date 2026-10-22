import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanıcı bildirimi (2026-10-22, ekran görüntüsü): OpenAPI dokümanında
/// `paths` altındaki blokları tek tek katlayınca satırlar üst üste biniyor,
/// özetler yanlış yerde çiziliyordu. Sebep: gizli satır sonları `.null` glyph
/// yapılıyordu; dizgici onları yine paragraf sonu sayıp satır durumunu
/// kaydırıyordu. Sentetik doküman, gerçek veri yok.
@MainActor
final class FoldingOverlapTests: XCTestCase {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    /// `paths` altında 8 uzun işlem (her biri ~120 satır); kullanıcının
    /// dokümanıyla aynı yapı (info, servers, components), değerler sentetik.
    private static func spec() -> String {
        func operation(_ index: Int) -> [String: Any] {
            let parameters = (0..<5).map { ["name": "x-header-\($0)", "in": "header", "required": false, "schema": ["type": "string"]] as [String: Any] }
            var responses: [String: Any] = [:]
            for code in ["200", "400", "409", "500", "502", "503"] {
                responses[code] = ["description": "D", "content": ["*/*": ["schema": ["$ref": "#/components/schemas/R\(index)"]]]]
            }
            return ["post": ["tags": ["T"], "operationId": "op\(index)", "parameters": parameters,
                             "requestBody": ["content": ["application/json": ["schema": ["$ref": "#/components/schemas/Q\(index)"]]], "required": true],
                             "responses": responses]]
        }
        var paths: [String: Any] = [:]
        for index in 0..<8 { paths["/path/number/\(index)"] = operation(index) }
        let document: [String: Any] = [
            "openapi": "3.0.1", "info": ["title": "T", "version": "v0"],
            "servers": [["url": "https://api.example.test", "description": "x"]],
            "paths": paths, "components": ["schemas": ["A": ["type": "object"]]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func assertSiblingFoldsLayOutOnSeparateLines(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let controller = CodeFoldingController()
        let host = NSHostingView(rootView: CodeEditor(text: .constant(text), language: .json, isEditable: false, folding: controller).frame(width: 550, height: 440))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 550, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let textView = try XCTUnwrap(find(NSTextView.self, in: host))
        let gutter = try XCTUnwrap(find(EditorGutter.self, in: host))

        let regions = JSONFolding.regions(in: text)
        let lines = text.components(separatedBy: "\n")
        let pathsLine = try XCTUnwrap(lines.firstIndex { $0.contains("\"paths\"") })
        let paths = try XCTUnwrap(regions.first { $0.openLine == pathsLine })
        let siblings = FoldRegion.outermost(regions.filter { $0.openLine > pathsLine && $0.closeLine < paths.closeLine })
        XCTAssertEqual(siblings.count, 8, file: file, line: line)
        // Kullanıcının yaptığı gibi: önce üstteki küçük bloklar, sonra yollar tek tek.
        let above = FoldRegion.outermost(regions.filter { $0.openLine > 0 && $0.openLine < pathsLine })
        for region in above + siblings {
            gutter.onToggleFold?(region.openLine)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let folding = try XCTUnwrap(layoutManager.delegate as? FoldingLayoutDelegate)
        let string = text as NSString
        layoutManager.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        var glyph = 0
        var lastY: CGFloat = -1
        var fragments = 0
        while glyph < layoutManager.numberOfGlyphs {
            var range = NSRange()
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            let characters = layoutManager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            let visibleBreaks = (characters.location..<NSMaxRange(characters)).filter {
                !folding.isHidden($0) && string.character(at: $0) == 10
            }
            XCTAssertLessThanOrEqual(visibleBreaks.count, 1, "satır parçası birden çok görünür satır taşıyor: \(characters)", file: file, line: line)
            XCTAssertGreaterThan(rect.minY, lastY, "satırlar üst üste: \(characters)", file: file, line: line)
            lastY = rect.minY
            glyph = NSMaxRange(range)
            fragments += 1
        }
        // Görünür satır sayısı: 8 açılış + 8 kapanış + çerçeve satırları.
        XCTAssertEqual(fragments, lines.count - (above + siblings).reduce(0) { $0 + ($1.closeLine - $1.openLine - 1) }, file: file, line: line)
    }

    func testSiblingFoldsDoNotOverlap() throws {
        try assertSiblingFoldsLayOutOnSeparateLines(Self.spec())
    }

    func testHiddenLineBreakDetection() {
        for unit: unichar in [0x0A, 0x0D, 0x85, 0x2028, 0x2029] { XCTAssertTrue(FoldingLayoutDelegate.isLineBreak(unit)) }
        XCTAssertFalse(FoldingLayoutDelegate.isLineBreak(0x20))
        XCTAssertFalse(FoldingLayoutDelegate.isLineBreak(0x09))
    }

    /// Kullanıcı ekran kaydı (2026-10-22, Workbench): kökü ya da `data`yı
    /// katlayınca yalnızca `{` kalıyor, özet ve kapanış görünmüyordu. Eski
    /// kodda kapanış `}` x = 66.113 pt'ye itiliyordu (ekran dışı). Derin,
    /// Jackson biçimli (" : ") sentetik yanıt; düzenlenebilir ve salt okunur.
    func testFoldedRootKeepsSummaryAndClosingOnScreen() throws {
        let products = (0..<12).map { index in
            """
                  {
                    "titleInfo" : null,
                    "fontType" : null,
                    "textKey" : "SYNTHETIC_TITLE_KEY_\(index)",
                    "info" : null,
                    "animationModel" : null,
                    "backgroundColorItem" : null,
                    "brandNew" : false,
                    "contentItems" : null,
                    "present" : false,
                    "action" : "başvur",
                    "description" : "\(index) ürün",
                    "textColor" : null,
                    "imageUrl" : "statics\\/example\\/hub\\/item_\(index).png",
                    "innerItems" : null,
                    "deeplink" : {
                      "parameters" : null,
                      "navigationCode" : 11000
                    },
                    "backgroundColor" : null,
                    "titleInfoItem" : null,
                    "textColorItem" : null
                  }
            """
        }
        let text = "{\n  \"Response\" : {\n    \"messageBoxes\" : null,\n    \"data\" : {\n      \"hubProducts\" : [\n        {\n          \"products\" : [\n"
            + products.joined(separator: ",\n") + "\n          ]\n        }\n      ]\n    }\n  }\n}"
        for editable in [false, true] {
            let controller = CodeFoldingController()
            let host = NSHostingView(rootView: CodeEditor(text: .constant(text), language: .json, isEditable: editable, folding: controller).frame(width: 450, height: 420))
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 450, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let textView = try XCTUnwrap(find(NSTextView.self, in: host))
            let gutter = try XCTUnwrap(find(EditorGutter.self, in: host))
            let layoutManager = try XCTUnwrap(textView.layoutManager)
            let container = try XCTUnwrap(textView.textContainer)
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: (text as NSString).length - 1)

            for (label, fold) in [("tümünü katla", { controller.collapseAll() }), ("kök", { controller.expandAll(); gutter.onToggleFold?(0) }),
                                  ("data", { controller.expandAll(); gutter.onToggleFold?(3) })] as [(String, () -> Void)] {
                fold()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                layoutManager.ensureLayout(for: container)
                let x = layoutManager.location(forGlyphAt: lastGlyph).x
                XCTAssertLessThan(x, container.size.width, "düzenlenebilir=\(editable) \(label): kapanış ekran dışında (x=\(x))")
            }
        }
    }
}
