import XCTest
@testable import Dev2KitCore

final class WorkbenchLimitsTests: XCTestCase {
    func testDecidedLimits() {
        // Kullanıcı kararı (2026-10-18).
        XCTAssertEqual(TextStats.size(WorkbenchLimits.maxInputBytes), "20 MB")
        XCTAssertEqual(TextStats.size(WorkbenchLimits.maxEditorLineBytes), "2.0 MB")
    }

    func testResultingBytesCountsUTF8() {
        let current = "aşb" as NSString // 4 bayt
        XCTAssertEqual(WorkbenchLimits.resultingBytes(of: current, replacing: NSRange(location: 1, length: 1), with: "ğğ"), 6)
        XCTAssertEqual(WorkbenchLimits.resultingBytes(of: current, replacing: NSRange(location: 3, length: 0), with: "x"), 5)
    }

    func testFastUpperBound() {
        XCTAssertFalse(WorkbenchLimits.mayExceed(utf16Length: 1000, limit: 3000))
        XCTAssertTrue(WorkbenchLimits.mayExceed(utf16Length: 1001, limit: 3000))
    }

    func testLongLineDetection() {
        let limit = 10
        XCTAssertFalse(WorkbenchLimits.hasLine(longerThan: limit, in: "0123456789\n0123456789"))
        XCTAssertTrue(WorkbenchLimits.hasLine(longerThan: limit, in: "kısa\n0123456789A\nkısa"))
        XCTAssertFalse(WorkbenchLimits.hasLine(longerThan: limit, in: "0123456789\r\n0123456789"))
        XCTAssertTrue(WorkbenchLimits.hasLine(longerThan: limit, in: "ğğğğğğ"), "bayt sayılır (12 bayt)")
    }

    func testMinifiedJSONOverTwoMBIsTooLargeForEditorButFormattedIsNot() throws {
        let row = #"{"id":1,"ad":"Müşteri"},"#
        let minified = "[" + String(repeating: row, count: 2 * 1_048_576 / row.utf8.count + 10) + "1]"
        XCTAssertTrue(WorkbenchLimits.isTooLargeForEditor(minified))
        let formatted = try JSONTool.format(minified, options: .init())
        XCTAssertFalse(WorkbenchLimits.isTooLargeForEditor(formatted), "biçimlenmiş hali editörde gösterilebilmeli")
    }

    func testDisplayedLineIsTruncated() {
        XCTAssertEqual(WorkbenchLimits.displayed(line: "kısa"), "kısa")
        let long = String(repeating: "x", count: 50_000)
        let shown = WorkbenchLimits.displayed(line: long)
        XCTAssertTrue(shown.hasPrefix(String(repeating: "x", count: WorkbenchLimits.maxDisplayedLineCharacters) + " … ("))
        XCTAssertTrue(shown.hasSuffix("line, truncated)"))
    }
}
