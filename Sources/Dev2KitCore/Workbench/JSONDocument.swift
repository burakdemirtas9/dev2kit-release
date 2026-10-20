import Foundation

/// Sıra koruyan JSON değeri.
///
/// `JSONSerialization` anahtar sırasını kaybediyor ve hatanın yerini yalnızca
/// "around line X" metniyle veriyor. Workbench'in ağaç görünümü, anahtar
/// sıralama, sıkıştırma ve kesin hata konumu için ayrı, küçük bir okuyucu.
///
/// - Sayılar METİN olarak saklanır: `12345678901234567890` ya da `1.10`
///   Double'a çevrilip bozulmaz (bankacılık verisinde kuruş/kimlik kaybı).
/// - `//` ve `/* */` yorumları boşluk sayılır (JSONC, `JSONFormatter` ile
///   aynı kabul); sıkıştırınca ve sıralayınca yorumlar düşer.
/// - Girintileme burada YAPILMAZ: kompakt çıktı `JSONFormatter`'dan geçer
///   (biçimlendirici yeniden yazılmaz — CLAUDE.md).
public indirect enum JSONValue: Equatable, Sendable {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    /// Kaynaktaki yazımıyla.
    case number(String)
    case bool(Bool)
    case null

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    /// Boşluksuz tek satır. `sortKeys`: nesne anahtarları her seviyede sıralı
    /// (Unicode kod noktası sırası — iki tarafta aynı sonucu verir).
    public func compact(sortKeys: Bool = false) -> String {
        var out = ""
        write(into: &out, sortKeys: sortKeys)
        return out
    }

    private func write(into out: inout String, sortKeys: Bool) {
        switch self {
        case .object(let members):
            out.append("{")
            let ordered = sortKeys ? members.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) } : members
            for (index, member) in ordered.enumerated() {
                if index > 0 { out.append(",") }
                out.append(JSONValue.quoted(member.key))
                out.append(":")
                member.value.write(into: &out, sortKeys: sortKeys)
            }
            out.append("}")
        case .array(let items):
            out.append("[")
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(",") }
                item.write(into: &out, sortKeys: sortKeys)
            }
            out.append("]")
        case .string(let text): out.append(JSONValue.quoted(text))
        case .number(let raw): out.append(raw)
        case .bool(let flag): out.append(flag ? "true" : "false")
        case .null: out.append("null")
        }
    }

    /// JSON string literali: `"`, `\`, kontrol karakterleri kaçışlanır;
    /// Türkçe ve diğer Unicode karakterler olduğu gibi kalır.
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
        return out
    }
}

/// `JSONValue` okuyucusu. Hata konumu satır/sütun olarak döner (1'den başlar).
public enum JSONDocument {
    /// İç içe geçme sınırı: özyinelemeli okuyucu derin girdide yığını
    /// taşırıp uygulamayı çökertmesin.
    public static let maxDepth = 512

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipSpace()
        guard !parser.atEnd else { throw parser.issue(L10n.t("beautify.empty"), at: 0) }
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.atEnd else { throw parser.issue(L10n.t("json.trailing"), at: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        /// Yorum taraması hata verdiyse (kapanmamış `/*`) konumu.
        var commentError: Int?

        var atEnd: Bool { index >= bytes.count }
        var current: UInt8 { bytes[index] }

        func issue(_ message: String, at offset: Int) -> WorkbenchIssue {
            WorkbenchIssue.at(offset: offset, in: bytes, message: L10n.t("json.invalid", message))
        }

        mutating func skipSpace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                case 0x2F where index + 1 < bytes.count && bytes[index + 1] == 0x2F:
                    while index < bytes.count && bytes[index] != 0x0A { index += 1 }
                case 0x2F where index + 1 < bytes.count && bytes[index + 1] == 0x2A:
                    let start = index
                    index += 2
                    while index + 1 < bytes.count && !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) { index += 1 }
                    if index + 1 >= bytes.count { commentError = start; index = bytes.count; return }
                    index += 2
                default: return
                }
            }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < JSONDocument.maxDepth else {
                throw issue(L10n.t("json.tooDeep", L10n.number(JSONDocument.maxDepth)), at: index)
            }
            if let commentError { throw issue(L10n.t("beautify.unclosedComment"), at: commentError) }
            guard !atEnd else { throw issue(L10n.t("json.unexpectedEnd"), at: index) }
            switch current {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
            default: throw issue(L10n.t("json.unexpectedChar", String(character(at: index))), at: index)
            }
        }

        func character(at offset: Int) -> String {
            String(decoding: bytes[offset..<min(offset + 1, bytes.count)], as: UTF8.self)
        }

        mutating func object(depth: Int) throws -> JSONValue {
            index += 1
            var members: [(key: String, value: JSONValue)] = []
            skipSpace()
            if !atEnd && current == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipSpace()
                guard !atEnd, current == UInt8(ascii: "\"") else {
                    throw issue(L10n.t("json.expectedKey"), at: index)
                }
                let key = try string()
                skipSpace()
                guard !atEnd, current == UInt8(ascii: ":") else { throw issue(L10n.t("json.expectedColon"), at: index) }
                index += 1
                skipSpace()
                members.append((key, try value(depth: depth + 1)))
                skipSpace()
                guard !atEnd else { throw issue(L10n.t("json.unclosedObject"), at: index) }
                if current == UInt8(ascii: ",") {
                    index += 1
                    skipSpace()
                    if !atEnd && current == UInt8(ascii: "}") { throw issue(L10n.t("json.trailingComma"), at: index) }
                    continue
                }
                if current == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw issue(L10n.t("json.expectedCommaBrace"), at: index)
            }
        }

        mutating func array(depth: Int) throws -> JSONValue {
            index += 1
            var items: [JSONValue] = []
            skipSpace()
            if !atEnd && current == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard !atEnd else { throw issue(L10n.t("json.unclosedArray"), at: index) }
                if current == UInt8(ascii: ",") {
                    index += 1
                    skipSpace()
                    if !atEnd && current == UInt8(ascii: "]") { throw issue(L10n.t("json.trailingComma"), at: index) }
                    continue
                }
                if current == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw issue(L10n.t("json.expectedCommaBracket"), at: index)
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<index + expected.count]) == expected else {
                throw issue(L10n.t("json.unexpectedValue"), at: index)
            }
            index += expected.count
        }

        mutating func number() throws -> String {
            let start = index
            func digits() -> Int {
                let from = index
                while !atEnd, current >= UInt8(ascii: "0"), current <= UInt8(ascii: "9") { index += 1 }
                return index - from
            }
            if current == UInt8(ascii: "-") { index += 1 }
            guard !atEnd else { throw issue(L10n.t("json.missingNumber"), at: start) }
            if current == UInt8(ascii: "0") {
                index += 1
            } else if digits() == 0 {
                throw issue(L10n.t("json.missingNumber"), at: start)
            }
            if !atEnd, current == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw issue(L10n.t("json.missingFraction"), at: index) }
            }
            if !atEnd, current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                index += 1
                if !atEnd, current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw issue(L10n.t("json.missingExponent"), at: index) }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func string() throws -> String {
            let start = index
            index += 1
            var scalars = String.UnicodeScalarView()
            var runStart = index
            func flushRun() {
                if runStart < index {
                    scalars.append(contentsOf: String(decoding: bytes[runStart..<index], as: UTF8.self).unicodeScalars)
                }
            }
            while true {
                guard !atEnd else { throw issue(L10n.t("json.unclosedString"), at: start) }
                let byte = current
                if byte == UInt8(ascii: "\"") {
                    flushRun()
                    index += 1
                    return String(scalars)
                }
                if byte < 0x20 {
                    throw issue(L10n.t("json.controlChar"), at: index)
                }
                if byte == UInt8(ascii: "\\") {
                    flushRun()
                    index += 1
                    guard !atEnd else { throw issue(L10n.t("json.unclosedString"), at: start) }
                    switch current {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        let escapeStart = index - 1
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code) {
                            // Vekil çifti: ikinci yarı `\uDC00…\uDFFF` olmalı.
                            guard index + 2 < bytes.count, bytes[index + 1] == UInt8(ascii: "\\"),
                                  bytes[index + 2] == UInt8(ascii: "u") else {
                                throw issue(L10n.t("json.missingSurrogate"), at: escapeStart)
                            }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw issue(L10n.t("json.invalidSurrogate"), at: escapeStart) }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw issue(L10n.t("json.invalidUnicode"), at: escapeStart) }
                        scalars.append(scalar)
                    default:
                        throw issue(L10n.t("json.invalidEscape", "\\" + String(character(at: index))), at: index - 1)
                    }
                    index += 1
                    runStart = index
                    continue
                }
                index += 1
            }
        }

        /// `\u` sonrasındaki dört hane; `index` son hanede kalır.
        mutating func hex4() throws -> UInt32 {
            guard index + 4 < bytes.count else { throw issue(L10n.t("json.missingUnicode"), at: index - 1) }
            var value: UInt32 = 0
            for offset in 1...4 {
                guard let digit = UInt32(String(UnicodeScalar(bytes[index + offset])), radix: 16) else {
                    throw issue(L10n.t("json.invalidUnicode"), at: index - 1)
                }
                value = value * 16 + digit
            }
            index += 4
            return value
        }
    }
}
