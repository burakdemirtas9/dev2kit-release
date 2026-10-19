import Foundation

/// CSV ayracı. JSON → CSV'de seçilir (`;` Türkçe Excel'in beklediği).
public enum CSVDelimiter: String, CaseIterable, Hashable, Sendable {
    case comma
    case semicolon
    case tab

    public var character: Character {
        switch self {
        case .comma: return ","
        case .semicolon: return ";"
        case .tab: return "\t"
        }
    }

    public var title: String {
        switch self {
        case .comma: return "Comma (,)"
        case .semicolon: return "Semicolon (;)"
        case .tab: return "Tab"
        }
    }
}

/// JSON → CSV (docs/V2.md "1e"; CSV → JSON 2026-10-20'de kullanıcı kararıyla
/// kaldırıldı). Kaçışlama RFC 4180: ayraç, tırnak ya da
/// satır sonu içeren hücre tırnaklanır, tırnak ikilenir.
///
/// JSON → CSV:
/// - Girdi nesne dizisi ya da tek nesne (tek satır).
/// - İç içe nesne noktalı sütun olur (`adres.il`); dizi hücreye JSON metni
///   olarak yazılır (satır çoğaltılmaz, kullanıcı kararı 2026-10-18).
/// - Sütun sırası ilk görülme sırası; eksik alan boş hücre.
public enum CSVConverter {
    // MARK: JSON → CSV

    public static func fromJSON(_ input: String, delimiter: CSVDelimiter) throws -> String {
        let records: [[(key: String, value: JSONValue)]]
        switch try JSONDocument.parse(input) {
        case .array(let items):
            records = try items.enumerated().map { index, item in
                guard case .object(let members) = item else {
                    throw WorkbenchIssue(message: "CSV için her eleman nesne olmalı; [\(index)] \(kindName(item))")
                }
                return members
            }
        case .object(let members):
            records = [members]
        case let other:
            throw WorkbenchIssue(message: "CSV için nesne dizisi ([{…}, {…}]) ya da tek nesne gerekli; girdi \(kindName(other))")
        }

        var columns: [String] = []
        var known = Set<String>()
        let rows: [[String: String]] = records.map { members in
            var row: [String: String] = [:]
            flatten(members, prefix: "", into: &row, columns: &columns, known: &known)
            return row
        }
        guard !columns.isEmpty else { return "" }

        let separator = String(delimiter.character)
        var lines = [columns.map { field($0, delimiter: delimiter) }.joined(separator: separator)]
        for row in rows {
            let cells = columns.map { field(row[$0] ?? "", delimiter: delimiter) }
            // Tek sütunda boş satır, okuyunca atlanan boş satıra dönüşmesin.
            lines.append(cells == [""] ? "\"\"" : cells.joined(separator: separator))
        }
        return lines.joined(separator: "\n")
    }

    private static func flatten(
        _ members: [(key: String, value: JSONValue)],
        prefix: String,
        into row: inout [String: String],
        columns: inout [String],
        known: inout Set<String>
    ) {
        for member in members {
            let name = prefix.isEmpty ? member.key : prefix + "." + member.key
            if case .object(let children) = member.value, !children.isEmpty {
                flatten(children, prefix: name, into: &row, columns: &columns, known: &known)
                continue
            }
            if known.insert(name).inserted { columns.append(name) }
            row[name] = cell(member.value)
        }
    }

    private static func cell(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let raw): return raw
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return ""
        case .object, .array: return value.compact()
        }
    }

    static func field(_ text: String, delimiter: CSVDelimiter) -> String {
        let needsQuotes = text.contains { $0 == delimiter.character || $0 == "\"" || $0.isNewline }
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func kindName(_ value: JSONValue) -> String {
        switch value {
        case .object: return "nesne"
        case .array: return "dizi"
        case .string: return "metin"
        case .number: return "sayı"
        case .bool: return "boolean"
        case .null: return "null"
        }
    }
}
