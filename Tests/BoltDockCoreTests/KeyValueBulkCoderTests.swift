import XCTest
@testable import BoltDockCore

final class KeyValueBulkCoderTests: XCTestCase {
    func testEncodesEntries() {
        let text = KeyValueBulkCoder.encode([
            KeyValueEntry(key: "Content-Type", value: "application/json"),
            KeyValueEntry(key: "X-Kapali", value: "1", enabled: false),
        ])
        XCTAssertEqual(text, "Content-Type: application/json\n//X-Kapali: 1")
    }

    func testEncodeSkipsFullyEmptyRows() {
        let text = KeyValueBulkCoder.encode([
            KeyValueEntry(key: "A", value: "1"),
            KeyValueEntry(),
        ])
        XCTAssertEqual(text, "A: 1")
    }

    func testDecodesLines() {
        let entries = KeyValueBulkCoder.decode("A: 1\n//B: 2")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].key, "A")
        XCTAssertEqual(entries[0].value, "1")
        XCTAssertTrue(entries[0].enabled)
        XCTAssertFalse(entries[1].enabled)
    }

    func testDecodeKeepsColonInsideValue() {
        let entries = KeyValueBulkCoder.decode("Referer: https://a.example.com/x")
        XCTAssertEqual(entries[0].value, "https://a.example.com/x")
    }

    func testDecodeSkipsIncompleteLines() {
        // Kullanıcı henüz ":" yazmamış olabilir; satır sessizce atlanır.
        let entries = KeyValueBulkCoder.decode("A: 1\nyazmaya basladim\n\nB: 2")
        XCTAssertEqual(entries.map(\.key), ["A", "B"])
    }

    func testRoundtripPreservesData() {
        let original = [
            KeyValueEntry(key: "A", value: "1"),
            KeyValueEntry(key: "B", value: "değer: iki", enabled: false),
        ]
        let decoded = KeyValueBulkCoder.decode(KeyValueBulkCoder.encode(original))
        XCTAssertEqual(decoded.map(\.key), original.map(\.key))
        XCTAssertEqual(decoded.map(\.value), original.map(\.value))
        XCTAssertEqual(decoded.map(\.enabled), original.map(\.enabled))
    }

    func testValidateReportsMissingSeparator() {
        let issues = KeyValueBulkCoder.validate("A: 1\nbozuk satir")
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].line, 2)
    }

    func testValidateReportsEmptyKey() {
        let issues = KeyValueBulkCoder.validate(": deger")
        XCTAssertEqual(issues.map(\.line), [1])
        XCTAssertTrue(issues[0].message.contains("anahtar"))
    }

    func testValidateIgnoresBlankLines() {
        XCTAssertTrue(KeyValueBulkCoder.validate("A: 1\n\n\nB: 2").isEmpty)
    }

    func testBeautifyNormalizesSpacing() throws {
        let result = try KeyValueBulkCoder.beautify("  A:1  \n\n//B :  2 ")
        XCTAssertEqual(result, "A: 1\n//B: 2")
    }

    func testBeautifyThrowsOnInvalidInput() {
        XCTAssertThrowsError(try KeyValueBulkCoder.beautify("A: 1\nbozuk"))
    }

    func testEntryValidationFindsDuplicatesAndEmptyKeys() {
        let issues = KeyValueBulkCoder.validate(entries: [
            KeyValueEntry(key: "Accept", value: "a"),
            KeyValueEntry(key: "accept", value: "b"),
            KeyValueEntry(key: "", value: "anahtarsiz"),
            KeyValueEntry(key: "X Boslukr", value: "c"),
        ])
        XCTAssertEqual(issues.count, 3)
        XCTAssertTrue(issues.contains { $0.message.contains("1. satırda") })
        XCTAssertTrue(issues.contains { $0.message.contains("anahtar boş") })
        XCTAssertTrue(issues.contains { $0.message.contains("boşluk") })
    }

    func testEntryValidationIgnoresFullyEmptyRow() {
        XCTAssertTrue(KeyValueBulkCoder.validate(entries: [KeyValueEntry()]).isEmpty)
    }
}
