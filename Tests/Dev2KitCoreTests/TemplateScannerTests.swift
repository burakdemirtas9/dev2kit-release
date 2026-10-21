import XCTest
@testable import Dev2KitCore

/// Güvenlik incelemesi (2026-10-21): şablon regex'i kapanmayan `{{` + boşlukta
/// geri izlemeyle patlıyordu (4.000 karakter: 358 sn). Yerine doğrusal tarayıcı;
/// eşleşme kuralı eski desenle birebir aynı olmalı.
final class TemplateScannerTests: XCTestCase {
    private let legacy = #/\{\{\s*([^{}]+?)\s*\}\}/#

    private func legacyMatches(_ text: String) -> [String] {
        text.matches(of: legacy).map { "\(text.distance(from: text.startIndex, to: $0.range.lowerBound)):\($0.output.0.count):\($0.1)" }
    }

    private func scannerMatches(_ text: String) -> [String] {
        TemplateScanner.matches(in: text).map { "\(text.distance(from: text.startIndex, to: $0.range.lowerBound)):\(text[$0.range].count):\($0.name)" }
    }

    /// Kısa her dizi: `{ } a boşluk satır sonu` alfabesinde 7 karaktere kadar.
    func testMatchesTheOldPatternExhaustively() {
        let alphabet: [Character] = ["{", "}", "a", " ", "\n"]
        var current: [String] = [""]
        var checked = 0
        for _ in 1...7 {
            current = current.flatMap { prefix in alphabet.map { prefix + String($0) } }
            for text in current {
                XCTAssertEqual(scannerMatches(text), legacyMatches(text), "\(text.debugDescription)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 90_000)
    }

    func testMatchesTheOldPatternOnRandomLongerText() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["{{", "}}", "{", "}", " ", "\t", "secret:x", "base", "ı", "\n", "a b"]
        for _ in 0..<3_000 {
            let text = (0..<40).map { _ in pieces.randomElement(using: &generator)! }.joined()
            XCTAssertEqual(scannerMatches(text), legacyMatches(text), text.debugDescription)
        }
    }

    func testOrdinaryTemplates() {
        XCTAssertEqual(TemplateScanner.matches(in: "{{base}}/a/{{ secret:token }}").map(\.name), ["base", "secret:token"])
        XCTAssertEqual(TemplateScanner.matches(in: "{\"a\":{\"b\":1}}").count, 0, "JSON süslüleri şablon değil")
    }

    /// PoC: eski desende dakikalar süren girdiler artık doğrusal.
    func testAdversarialInputIsLinear() throws {
        let unclosed = "{{" + String(repeating: " ", count: 200_000) + "}"
        let jsonTail = "{\"a\":\"{{" + String(repeating: " \t", count: 100_000) + "x\"}}"
        let resolver = VariableResolver(environment: nil, secretStore: InMemorySecretStore())
        for text in [unclosed, jsonTail] {
            let start = Date()
            _ = try? resolver.resolve(text)
            _ = TemplateVariables.variableRanges(in: text)
            _ = SecretReferences.names(in: RequestModel(body: .raw(content: text, contentType: "application/json")), environment: nil)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        }
    }
}
