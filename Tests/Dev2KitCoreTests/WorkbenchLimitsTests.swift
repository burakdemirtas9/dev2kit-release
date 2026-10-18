import XCTest
@testable import Dev2KitCore

final class WorkbenchLimitsTests: XCTestCase {
    func testDecidedLimits() {
        // Kullanıcı kararı (2026-10-18).
        XCTAssertEqual(TextStats.size(WorkbenchLimits.maxInputBytes), "4.0 MB")
        XCTAssertEqual(TextStats.size(WorkbenchLimits.maxEditorLineBytes), "1.0 MB")
    }

    func testLineCountTreatsCRLFOnceAndLoneCRAsABreak() {
        XCTAssertEqual(TextStats.lineCount(""), 0)
        XCTAssertEqual(TextStats.lineCount("a"), 1)
        XCTAssertEqual(TextStats.lineCount("a\nb"), 2)
        XCTAssertEqual(TextStats.lineCount("a\r\nb"), 2)
        XCTAssertEqual(TextStats.lineCount("a\rb\rc"), 3)
        XCTAssertEqual(TextStats.lineCount("a\n"), 2)
        XCTAssertEqual(TextStats("a\r\nb\rc").lines, 3, "sayaç da aynı kural")
        XCTAssertEqual(WorkbenchLimits.maxInputLines, 16_000)
    }

    /// Editör kapısı büyüyen her değişiklikte sayıyor. Ölçüm (M4, release,
    /// 2026-10-18): 4 MB (izin verilen en büyük girdi) 3–4 ms/tuş — bir ekran
    /// karesinin altında. Süre debug'da dalgalandığı için burada sınanmıyor.
    func testNSStringLineCountMatchesTheStringRule() {
        for sample in ["", "a", "a\nb", "a\r\nb", "a\rb\rc", "a\n", "ğ\r\n\r\nx"] {
            XCTAssertEqual(TextStats.lineCount(sample as NSString), TextStats.lineCount(sample), sample.debugDescription)
        }
        // Parça (64 K) sınırına denk gelen \r\n bir kez sayılmalı.
        let boundary = String(repeating: "a", count: 65_535) + "\r\n" + "b"
        XCTAssertEqual(TextStats.lineCount(boundary as NSString), 2)
        let text = String(repeating: #"  "ad": "Müşteri","# + "\n", count: 190_000) as NSString // ~4 MB
        XCTAssertEqual(TextStats.lineCount(text), 190_001)
    }

    func testOutputEditIssueCoversBytesAndLines() {
        XCTAssertNil(WorkbenchLimits.outputEditIssue("a\nb"))
        XCTAssertNotNil(WorkbenchLimits.outputEditIssue(String(repeating: "\n", count: 16_000)))
        XCTAssertNil(WorkbenchLimits.outputEditIssue(String(repeating: "\n", count: 15_999)))
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
