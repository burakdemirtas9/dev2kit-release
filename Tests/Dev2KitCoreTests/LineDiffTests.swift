import XCTest
@testable import Dev2KitCore

final class LineDiffTests: XCTestCase {
    private func lines(_ text: String) -> [String] { text.isEmpty ? [] : text.components(separatedBy: "\n") }

    /// İşlemler soldan sağı birebir üretmeli ve her satır bir kez kullanılmalı.
    private func assertReconstructs(_ left: [String], _ right: [String], _ result: LineDiff.Result, file: StaticString = #filePath, line: UInt = #line) {
        var rebuilt: [String] = []
        var usedLeft: [Int] = []
        for op in result.operations {
            switch op {
            case .equal(let l, let r):
                XCTAssertEqual(left[l], right[r], file: file, line: line)
                rebuilt.append(right[r]); usedLeft.append(l)
            case .insert(let r): rebuilt.append(right[r])
            case .delete(let l): usedLeft.append(l)
            }
        }
        XCTAssertEqual(rebuilt, right, file: file, line: line)
        XCTAssertEqual(usedLeft, Array(left.indices), "sol satırlar sırayla, bir kez", file: file, line: line)
    }

    private func edits(_ result: LineDiff.Result) -> Int {
        result.operations.filter { if case .equal = $0 { return false }; return true }.count
    }

    /// En küçük düzenleme sayısı: n + m - 2·LCS (basit DP; yalnızca küçük girdilerde).
    private func minimalEdits(_ a: [String], _ b: [String]) -> Int {
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        return a.count + b.count - 2 * dp[0][0]
    }

    func testKnownCases() {
        let left = lines("a\nb\nc\nd"), right = lines("a\nx\nc\nd\ne")
        let result = LineDiff.diff(left, right)
        assertReconstructs(left, right, result)
        XCTAssertEqual(edits(result), 3)
        XCTAssertFalse(result.isSimplified)

        for (l, r) in [("", ""), ("", "a\nb"), ("a\nb", ""), ("a", "a"), ("a\nb\nc", "c\nb\na")] {
            let a = lines(l), b = lines(r)
            let result = LineDiff.diff(a, b, options: .init(), algorithm: .myers)
            assertReconstructs(a, b, result)
            XCTAssertEqual(edits(result), minimalEdits(a, b), "\(l) → \(r)")
            assertReconstructs(a, b, LineDiff.diff(a, b))
        }
    }

    func testRandomInputsAreMinimalAndReconstruct() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            let a = (0..<Int.random(in: 0...14, using: &generator)).map { _ in ["a", "b", "c", "d"].randomElement(using: &generator)! }
            let b = (0..<Int.random(in: 0...14, using: &generator)).map { _ in ["a", "b", "c", "d"].randomElement(using: &generator)! }
            // Myers en küçük sonucu verir; patience (varsayılan) her zaman doğru
            // ama en küçük olmak zorunda değil.
            let myers = LineDiff.diff(a, b, options: .init(), algorithm: .myers)
            assertReconstructs(a, b, myers)
            XCTAssertEqual(edits(myers), minimalEdits(a, b), "\(a) → \(b)")
            assertReconstructs(a, b, LineDiff.diff(a, b))
        }
    }

    func testIgnoreOptions() {
        let left = ["  a  b", "C"], right = ["a b", "c"]
        XCTAssertEqual(edits(LineDiff.diff(left, right)), 4)
        XCTAssertEqual(edits(LineDiff.diff(left, right, options: .init(ignoreWhitespace: true))), 2)
        XCTAssertEqual(edits(LineDiff.diff(left, right, options: .init(ignoreWhitespace: true, ignoreCase: true))), 0)
    }

    func testPatienceSplitsManyChangesIntoSmallPieces() {
        // Tekil satırlar sabit nokta: her üç satırdan biri değişse de sadeleşmez.
        let left = (0..<9_000).map { "satır \($0)" }
        let right = left.enumerated().map { $0.offset % 3 == 0 ? "değişti \($0.offset)" : $0.element }
        let result = LineDiff.diff(left, right)
        XCTAssertFalse(result.isSimplified)
        XCTAssertEqual(edits(result), 6_000)
        assertReconstructs(left, right, result)
    }

    func testTooManyDifferencesAreSimplifiedNotHung() {
        let left = (0..<6_000).map { "l\($0)" }, right = (0..<6_000).map { "r\($0)" }
        let result = LineDiff.diff(left, right)
        XCTAssertTrue(result.isSimplified)
        assertReconstructs(left, right, result)
    }

    func testRowsPairChangesSideBySide() {
        let left = lines("a\nb\nc"), right = lines("a\nB\nc\nd")
        let rows = DiffRow.rows(LineDiff.diff(left, right).operations, left: left, right: right)
        XCTAssertEqual(rows.map(\.kind), [.equal, .changed, .equal, .added])
        XCTAssertEqual(rows[1].left?.text, "b")
        XCTAssertEqual(rows[1].right?.text, "B")
        XCTAssertEqual(rows[3].right?.number, 4)
        XCTAssertNil(rows[3].left)
        XCTAssertEqual(DiffRow.changeStarts(rows), [1, 3])
    }
}
