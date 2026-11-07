import Foundation

/// Senaryonun request body'si gelen gövdeyle nasıl karşılaştırılır
/// (kullanıcı isteği, 2026-11-07: "aynı servis, aynı header, farklı body →
/// farklı response").
public enum MockBodyMatch: String, Codable, CaseIterable, Sendable {
    /// Senaryodaki alanlar gelen gövdede aynı değerle varsa eşleşir; fazladan
    /// alanlar (requestId, zaman damgası…) yok sayılır. JSON değilse: metin içerir.
    case contains
    /// JSON olarak tam eşit (alan sırası ve boşluk önemsiz); değilse metin eşit.
    case exact
}

/// Gövde karşılaştırması. JSON'da alan sırası ve boşluk önemsiz, sayılar
/// değer olarak (100 = 100.0 = 1e2); diziler sıralı ve aynı uzunlukta.
public enum MockBodyMatcher {
    /// Senaryodaki örnek gövde: JSON ise ayrıştırılmış, değilse kırpılmış metin.
    public enum Example: Sendable {
        case none
        case json(JSONValue)
        case text(String)
    }

    public static func example(_ text: String) -> Example {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if let value = try? JSONDocument.parse(trimmed) { return .json(value) }
        return .text(trimmed)
    }

    /// `actualJSON` yalnızca örnek JSON ise ve gerekirse çağrılır (gövde bir kez okunur).
    public static func matches(_ example: Example, mode: MockBodyMatch, actualText: String, actualJSON: () -> JSONValue?) -> Bool {
        switch example {
        case .none:
            return true
        case .json(let expected):
            guard let actual = actualJSON() else { return false }
            return mode == .contains ? contains(actual, expected) : equal(actual, expected)
        case .text(let expected):
            let actual = actualText.trimmingCharacters(in: .whitespacesAndNewlines)
            return mode == .contains ? actual.contains(expected) : actual == expected
        }
    }

    /// `actual`, `expected`'teki her alanı aynı değerle içeriyor mu (fazlası serbest).
    public static func contains(_ actual: JSONValue, _ expected: JSONValue) -> Bool {
        switch (actual, expected) {
        case let (.object(actualFields), .object(expectedFields)):
            return expectedFields.allSatisfy { field in
                guard let value = actualFields.first(where: { $0.key == field.key })?.value else { return false }
                return contains(value, field.value)
            }
        case let (.array(actualItems), .array(expectedItems)):
            return actualItems.count == expectedItems.count && zip(actualItems, expectedItems).allSatisfy { contains($0, $1) }
        default:
            return equal(actual, expected)
        }
    }

    /// Yapısal eşitlik; nesnede alan sırası önemsiz.
    public static func equal(_ left: JSONValue, _ right: JSONValue) -> Bool {
        switch (left, right) {
        case let (.object(a), .object(b)):
            guard Set(a.map(\.key)) == Set(b.map(\.key)) else { return false }
            return b.allSatisfy { field in
                guard let value = a.first(where: { $0.key == field.key })?.value else { return false }
                return equal(value, field.value)
            }
        case let (.array(a), .array(b)):
            return a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
        case let (.number(a), .number(b)):
            return numbersEqual(a, b)
        case let (.string(a), .string(b)):
            return a == b
        case let (.bool(a), .bool(b)):
            return a == b
        case (.null, .null):
            return true
        default:
            return false
        }
    }

    static func numbersEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let locale = Locale(identifier: "en_US_POSIX")
        guard let left = Decimal(string: a, locale: locale), let right = Decimal(string: b, locale: locale) else { return false }
        return left == right
    }

    /// Önce gelen senaryo (`earlier`), sonrakinin (`later`) gövde açısından
    /// eşleşeceği her isteği de karşılıyor mu. Gölgeleme uyarısı için.
    static func covers(_ earlier: Example, _ earlierMode: MockBodyMatch, _ later: Example, _ laterMode: MockBodyMatch) -> Bool {
        switch (earlier, later) {
        case (.none, _):
            return true
        case let (.json(e), .json(l)):
            return earlierMode == .contains ? contains(l, e) : (laterMode == .exact && equal(l, e))
        case let (.text(e), .text(l)):
            return earlierMode == .contains ? l.contains(e) : (laterMode == .exact && l == e)
        default:
            return false
        }
    }
}
