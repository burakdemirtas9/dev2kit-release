import Foundation

/// CSV ayracı. JSON → CSV'de seçilir (`;` Türkçe Excel'in beklediği);
/// CSV → JSON'da ilk satırdan algılanır.
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

/// JSON ↔ CSV (docs/V2.md "1e"). Kaçışlama RFC 4180: ayraç, tırnak ya da
/// satır sonu içeren hücre tırnaklanır, tırnak ikilenir.
///
/// JSON → CSV:
/// - Girdi nesne dizisi ya da tek nesne (tek satır).
/// - İç içe nesne noktalı sütun olur (`adres.il`); dizi hücreye JSON metni
///   olarak yazılır (satır çoğaltılmaz, kullanıcı kararı 2026-10-18).
/// - Sütun sırası ilk görülme sırası; eksik alan boş hücre.
///
/// CSV → JSON:
/// - İlk satır başlık; noktalı başlık iç içe nesne olur (ters yön tutarlı).
///   Başka bir başlık onun ön ekiyse (`a` ve `a.b`) iç içe kurulmaz, düz kalır.
/// - Boş başlık `columnN`, tekrar eden başlık `ad_2`; başlıktan uzun satırın
///   fazlası `columnN`; kısa satırın eksiği boş hücre.
/// - Tipler `ValueInference` ile (varsayılan açık, kullanıcı kararı).
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

    // MARK: CSV → JSON

    public static func toJSON(_ input: String, detectTypes: Bool, indent: String) throws -> String {
        let text = withoutBOM(input)
        let records = try parse(text, delimiter: detectDelimiter(text))
        guard let header = records.first else { return "[]" }
        let names = columnNames(header)
        let nestedPaths = paths(for: names)

        var objects: [JSONValue] = []
        for record in records.dropFirst() {
            var members: [(key: String, value: JSONValue)] = []
            for index in 0..<max(names.count, record.count) {
                let name = index < names.count ? names[index] : "column\(index + 1)"
                let raw = index < record.count ? record[index] : ""
                let value = detectTypes ? ValueInference.value(of: raw, emptyIsNull: true) : .string(raw)
                let path = index < nestedPaths.count ? nestedPaths[index] : [name]
                if !insert(value, at: path[...], into: &members), !insert(value, at: [name], into: &members) {
                    members.append((name, value))
                }
            }
            objects.append(.object(members))
        }
        return try JSONFormatter.beautify(JSONValue.array(objects).compact(), indent: indent)
    }

    /// Girdi doğrulaması: kayıtlara ayrılabiliyor mu (kapanmamış tırnak).
    public static func validate(_ input: String) -> WorkbenchValidation {
        let text = withoutBOM(input)
        do {
            _ = try parse(text, delimiter: detectDelimiter(text))
            return .valid
        } catch let issue as WorkbenchIssue {
            return .invalid(issue)
        } catch {
            return .invalid(WorkbenchIssue(message: error.localizedDescription))
        }
    }

    /// Excel UTF-8 dışa aktarımı BOM ile başlar; ilk başlığa yapışmasın.
    private static func withoutBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// İlk kayıtta (tırnak dışında) en çok geçen ayraç; hiçbiri yoksa virgül.
    static func detectDelimiter(_ text: String) -> CSVDelimiter {
        var counts: [CSVDelimiter: Int] = [:]
        var inQuotes = false
        for character in text {
            if character == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if isLineBreak(character) { break }
            if let delimiter = CSVDelimiter.allCases.first(where: { $0.character == character }) {
                counts[delimiter, default: 0] += 1
            }
        }
        return CSVDelimiter.allCases.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
            .flatMap { (counts[$0] ?? 0) > 0 ? $0 : nil } ?? .comma
    }

    /// RFC 4180 okuyucu. Hoşgörülü: tırnaklı alanın ardından gelen karakter
    /// alana eklenir, alan ortasındaki tırnak düz karakterdir. Tek hata:
    /// kapanmamış tırnak. Tamamen boş satırlar atlanır.
    static func parse(_ text: String, delimiter: CSVDelimiter) throws -> [[String]] {
        let separator = delimiter.character
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var recordHadQuotes = false
        var quoteStart = 0
        var offset = 0
        var index = text.startIndex

        func endRecord() {
            record.append(field)
            if !(record == [""] && !recordHadQuotes) { records.append(record) }
            record = []
            field = ""
            fieldWasQuoted = false
            recordHadQuotes = false
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inQuotes {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        offset += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else if character == "\"", field.isEmpty, !fieldWasQuoted {
                inQuotes = true
                fieldWasQuoted = true
                recordHadQuotes = true
                quoteStart = offset
            } else if character == separator {
                record.append(field)
                field = ""
                fieldWasQuoted = false
            } else if isLineBreak(character) {
                endRecord()
            } else {
                field.append(character)
            }
            index = next
            offset += 1
        }
        if inQuotes {
            throw WorkbenchIssue.at(characterOffset: quoteStart, in: Array(text), message: "Kapanmamış tırnak")
        }
        if !field.isEmpty || fieldWasQuoted || !record.isEmpty { endRecord() }
        return records
    }

    /// `\r\n` Swift'te tek karakter. U+2028 gibi diğer satır sonları alan içeriği sayılır.
    private static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }

    static func columnNames(_ header: [String]) -> [String] {
        var used = Set<String>()
        return header.enumerated().map { index, raw in
            let base = raw.trimmingCharacters(in: .whitespaces).isEmpty ? "column\(index + 1)" : raw
            var name = base
            var suffix = 2
            while used.contains(name) {
                name = "\(base)_\(suffix)"
                suffix += 1
            }
            used.insert(name)
            return name
        }
    }

    /// Her sütunun yolu: noktalı ve hiçbir başlık ön eki değilse parçalar,
    /// aksi halde tek parça (düz anahtar).
    static func paths(for names: [String]) -> [[String]] {
        let all = Set(names)
        return names.map { name in
            let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count > 1, !parts.contains(where: \.isEmpty) else { return [name] }
            for length in 1..<parts.count where all.contains(parts[0..<length].joined(separator: ".")) {
                return [name]
            }
            return parts
        }
    }

    /// Yolu izleyerek ekler; yol üstünde nesne olmayan bir değer ya da aynı
    /// anahtar varsa `false` (çağıran düz anahtara düşer).
    private static func insert(_ value: JSONValue, at path: ArraySlice<String>, into members: inout [(key: String, value: JSONValue)]) -> Bool {
        guard let key = path.first else { return false }
        let existing = members.firstIndex { $0.key == key }
        if path.count == 1 {
            guard existing == nil else { return false }
            members.append((key, value))
            return true
        }
        if let existing {
            guard case .object(var child) = members[existing].value,
                  insert(value, at: path.dropFirst(), into: &child) else { return false }
            members[existing].value = .object(child)
            return true
        }
        var child: [(key: String, value: JSONValue)] = []
        guard insert(value, at: path.dropFirst(), into: &child) else { return false }
        members.append((key, .object(child)))
        return true
    }
}
