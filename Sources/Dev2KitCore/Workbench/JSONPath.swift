import Foundation

/// JSONPath sorgusu (RFC 9535, 2024) — Workbench "JSONPath" aracı.
///
/// Harici kütüphane yok (CLAUDE.md): RFC'nin sözdizimi küçük, burada yazıldı.
/// Desteklenen: `$`, `.ad`, `['ad']` / `["ad"]`, `[0]` / `[-1]`, `*`, `..`,
/// dilim `[başla:bitir:adım]`, birleşim `[0,2]` / `['a','b']`, filtre
/// `[?ifade]` (`@`, `$`, `== != < <= > >=`, `&& || !`, parantez, sayı/metin/
/// true/false/null), işlevler `length count match search value`.
///
/// Bilinçli sınırlar: Goessner'in betik ifadeleri (`[(@.length-1)]`) RFC'de
/// yok, açık bir mesajla reddedilir. `match`/`search` düzenli ifadeleri ICU
/// (`NSRegularExpression`) ile çalışır; RFC'nin I-Regexp alt kümesinden
/// geniştir. Sayı karşılaştırması `Decimal` iledir.
///
/// Hepsi yerelde çalışır; ağ yok. Pahalı sorgu (iç içe `..` filtreleri)
/// arayüzü dondurmasın diye iş bütçesi ve eşleşme sınırı var; araç zaten
/// arka planda çalışır (`BackgroundWork`).
public enum JSONPath {
    public static let maxQueryLength = 4_096
    public static let maxMatches = 100_000
    /// Değerlendirmede ziyaret edilecek en fazla düğüm sayısı.
    static let workBudget = 20_000_000

    /// Sorgu hatası: 1'den başlayan sütunla.
    public struct QueryError: Error, Equatable, LocalizedError {
        public let message: String
        public let column: Int

        public var errorDescription: String? { L10n.t("jsonpath.error", L10n.number(column), message) }
    }

    /// Değerlendirme sınırı aşıldı (sorgu geçerli ama çok pahalı ya da çok
    /// fazla eşleşme).
    public struct LimitError: Error, Equatable, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func evaluate(_ query: String, on root: JSONValue) throws -> [JSONValue] {
        let compiled = try compile(query)
        var context = Context(root: root)
        return try context.run(compiled.segments, from: [root])
    }

    public static func compile(_ query: String) throws -> Query {
        guard query.count <= maxQueryLength else {
            throw QueryError(message: L10n.t("jsonpath.tooLong", L10n.number(maxQueryLength)), column: maxQueryLength + 1)
        }
        var parser = Parser(query)
        return try parser.parseQuery()
    }

    // MARK: - Sözdizimi ağacı

    public struct Query: Sendable {
        let segments: [Segment]
    }

    struct Segment: Sendable {
        let descendant: Bool
        let selectors: [Selector]
    }

    indirect enum Selector: Sendable {
        case name(String)
        case wildcard
        case index(Int)
        case slice(start: Int?, end: Int?, step: Int?)
        case filter(LogicalExpr)
    }

    indirect enum LogicalExpr: Sendable {
        case or([LogicalExpr])
        case and([LogicalExpr])
        case not(LogicalExpr)
        case comparison(Comparable, ComparisonOp, Comparable)
        /// Sorgu ya da mantıksal işlev: düğüm varsa / doğruysa.
        case test(TestOperand)
    }

    enum ComparisonOp: String, Sendable { case eq = "==", ne = "!=", lt = "<", le = "<=", gt = ">", ge = ">=" }

    enum TestOperand: Sendable {
        case query(FilterQuery)
        case function(FunctionCall)
    }

    indirect enum Comparable: Sendable {
        case literal(JSONValue)
        case query(FilterQuery)
        case function(FunctionCall)
    }

    struct FilterQuery: Sendable {
        /// `@` (geçerli düğüm) ya da `$` (kök).
        let relative: Bool
        let segments: [Segment]

        /// Tekil sorgu: yalnızca ad ve indeks seçicileri, `..` yok (karşılaştırmada şart).
        var isSingular: Bool {
            segments.allSatisfy { segment in
                !segment.descendant && segment.selectors.count == 1 && {
                    switch segment.selectors[0] {
                    case .name, .index: return true
                    default: return false
                    }
                }()
            }
        }
    }

    enum FunctionName: String, Sendable, CaseIterable { case length, count, match, search, value }

    struct FunctionCall: Sendable {
        let name: FunctionName
        let arguments: [FunctionArgument]
        /// `match`/`search`'te düzenli ifade metin olarak verildiyse önceden derlenir.
        let pattern: NSRegularExpressionBox?
    }

    indirect enum FunctionArgument: Sendable {
        case literal(JSONValue)
        case query(FilterQuery)
        case function(FunctionCall)
        case logical(LogicalExpr)
    }

    /// `NSRegularExpression` Sendable değil; değişmez kullanılıyor.
    final class NSRegularExpressionBox: @unchecked Sendable {
        let regex: NSRegularExpression
        init(_ regex: NSRegularExpression) { self.regex = regex }
    }

    // MARK: - Ayrıştırıcı

    struct Parser {
        let chars: [Character]
        var index = 0

        init(_ text: String) { chars = Array(text) }

        var atEnd: Bool { index >= chars.count }
        var current: Character? { atEnd ? nil : chars[index] }
        func peek(_ offset: Int = 0) -> Character? {
            index + offset < chars.count ? chars[index + offset] : nil
        }

        func error(_ message: String, at position: Int? = nil) -> QueryError {
            QueryError(message: message, column: (position ?? index) + 1)
        }

        mutating func skipBlank() {
            while let character = current, character == " " || character == "\t" || character == "\n" || character == "\r" {
                index += 1
            }
        }

        mutating func parseQuery() throws -> Query {
            skipBlank()
            guard current == "$" else {
                if current == "@" { throw error(L10n.t("jsonpath.atOutside")) }
                throw error(atEnd ? L10n.t("jsonpath.empty") : L10n.t("jsonpath.startDollar"))
            }
            index += 1
            let segments = try parseSegments(inFilter: false)
            skipBlank()
            guard atEnd else { throw error(L10n.t("jsonpath.unexpected", String(current!))) }
            return Query(segments: segments)
        }

        /// `.ad`, `.*`, `[…]`, `..ad`, `..*`, `..[…]` dizisi.
        mutating func parseSegments(inFilter: Bool) throws -> [Segment] {
            var segments: [Segment] = []
            while true {
                let save = index
                skipBlank()
                guard let character = current else { index = save; return segments }
                if character == "." {
                    if peek(1) == "." {
                        index += 2
                        if current == "[" {
                            segments.append(Segment(descendant: true, selectors: try parseBracket()))
                        } else if current == "*" {
                            index += 1
                            segments.append(Segment(descendant: true, selectors: [.wildcard]))
                        } else {
                            segments.append(Segment(descendant: true, selectors: [.name(try parseShorthandName())]))
                        }
                    } else {
                        index += 1
                        if current == "*" {
                            index += 1
                            segments.append(Segment(descendant: false, selectors: [.wildcard]))
                        } else {
                            segments.append(Segment(descendant: false, selectors: [.name(try parseShorthandName())]))
                        }
                    }
                } else if character == "[" {
                    segments.append(Segment(descendant: false, selectors: try parseBracket()))
                } else {
                    // Segment değil: çağıran devam eder (filtrede operatör vb.).
                    index = save
                    return segments
                }
            }
        }

        static func isNameFirst(_ character: Character) -> Bool {
            character == "_" || (character.isASCII && character.isLetter) || !character.isASCII
        }

        static func isNameChar(_ character: Character) -> Bool {
            isNameFirst(character) || (character.isASCII && character.isNumber)
        }

        mutating func parseShorthandName() throws -> String {
            let start = index
            guard let first = current else { throw error(L10n.t("jsonpath.expectedName")) }
            guard Self.isNameFirst(first) else {
                if first.isNumber { throw error(L10n.t("jsonpath.nameDigit", String(first))) }
                throw error(L10n.t("jsonpath.expectedNameSpecial"))
            }
            while let character = current, Self.isNameChar(character) { index += 1 }
            // Tireli ad (ör. .content-type): RFC kısayolunda yok; yol göster.
            if current == "-", let next = peek(1), Self.isNameChar(next) {
                var end = index
                while end < chars.count, Self.isNameChar(chars[end]) || chars[end] == "-" { end += 1 }
                let full = String(chars[start..<end])
                throw error(L10n.t("jsonpath.dash", full), at: index)
            }
            return String(chars[start..<index])
        }

        /// `[` seçiciler `]`.
        mutating func parseBracket() throws -> [Selector] {
            let open = index
            index += 1 // [
            var selectors: [Selector] = []
            while true {
                skipBlank()
                selectors.append(try parseSelector())
                skipBlank()
                if current == "," { index += 1; continue }
                if current == "]" { index += 1; return selectors }
                if atEnd { throw error(L10n.t("jsonpath.unclosedBracket"), at: open) }
                throw error(L10n.t("jsonpath.expectedCommaBracket", String(current!)))
            }
        }

        mutating func parseSelector() throws -> Selector {
            guard let character = current else { throw error(L10n.t("jsonpath.expectedSelector")) }
            switch character {
            case "'", "\"":
                return .name(try parseStringLiteral())
            case "*":
                index += 1
                return .wildcard
            case "?":
                index += 1
                skipBlank()
                return .filter(try parseLogicalOr())
            case "(":
                throw error(L10n.t("jsonpath.script"))
            case ":":
                return try parseSlice(start: nil)
            default:
                if character == "-" || character.isNumber {
                    let position = index
                    let number = try parseInteger()
                    skipBlank()
                    if current == ":" { return try parseSlice(start: number) }
                    _ = position
                    return .index(number)
                }
                if Self.isNameFirst(character) {
                    throw error(L10n.t("jsonpath.quoteNames", String(String(chars[index..<min(chars.count, index + 20)]).prefix { Self.isNameChar($0) })))
                }
                throw error(L10n.t("jsonpath.unexpectedInBrackets", String(character)))
            }
        }

        mutating func parseSlice(start: Int?) throws -> Selector {
            index += 1 // :
            skipBlank()
            var end: Int?
            var step: Int?
            if let character = current, character == "-" || character.isNumber { end = try parseInteger() }
            skipBlank()
            if current == ":" {
                index += 1
                skipBlank()
                if let character = current, character == "-" || character.isNumber { step = try parseInteger() }
            }
            return .slice(start: start, end: end, step: step)
        }

        /// RFC tamsayısı: baştaki sıfır yok, `-0` yok, ±(2^53−1).
        mutating func parseInteger() throws -> Int {
            let start = index
            if current == "-" { index += 1 }
            guard let first = current, first.isASCII, first.isNumber else { throw error(L10n.t("jsonpath.expectedNumber"), at: start) }
            if first == "0", let next = peek(1), next.isASCII, next.isNumber {
                throw error(L10n.t("jsonpath.leadingZero"), at: start)
            }
            while let character = current, character.isASCII, character.isNumber { index += 1 }
            let text = String(chars[start..<index])
            if text == "-0" { throw error(L10n.t("jsonpath.minusZero"), at: start) }
            guard let value = Int(text), abs(value) <= 9_007_199_254_740_991 else {
                throw error(L10n.t("jsonpath.outOfRange", text), at: start)
            }
            return value
        }

        mutating func parseStringLiteral() throws -> String {
            let quote = current!
            let open = index
            index += 1
            var result = ""
            while true {
                guard let character = current else { throw error(L10n.t("json.unclosedString"), at: open) }
                index += 1
                if character == quote { return result }
                if character == "\\" {
                    guard let escaped = current else { throw error(L10n.t("yaml.halfEscape"), at: index - 1) }
                    index += 1
                    switch escaped {
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "/": result.append("/")
                    case "\\": result.append("\\")
                    case "'" where quote == "'": result.append("'")
                    case "\"" where quote == "\"": result.append("\"")
                    case "u": result.unicodeScalars.append(try parseUnicodeEscape())
                    default: throw error(L10n.t("json.invalidEscape", "\\\(escaped)"), at: index - 2)
                    }
                } else {
                    if let scalar = character.unicodeScalars.first, scalar.value < 0x20 {
                        throw error(L10n.t("json.controlChar"), at: index - 1)
                    }
                    result.append(character)
                }
            }
        }

        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let start = index - 2
            func hex4() throws -> UInt32 {
                guard index + 4 <= chars.count, let value = UInt32(String(chars[index..<index + 4]), radix: 16) else {
                    throw error(L10n.t("jsonpath.fourHex"), at: start)
                }
                index += 4
                return value
            }
            let high = try hex4()
            if (0xD800...0xDBFF).contains(high) {
                guard current == "\\", peek(1) == "u" else { throw error(L10n.t("json.missingSurrogate"), at: start) }
                index += 2
                let low = try hex4()
                guard (0xDC00...0xDFFF).contains(low),
                      let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)) else {
                    throw error(L10n.t("json.invalidSurrogate"), at: start)
                }
                return scalar
            }
            guard let scalar = Unicode.Scalar(high), !(0xDC00...0xDFFF).contains(high) else {
                throw error(L10n.t("json.invalidUnicode"), at: start)
            }
            return scalar
        }

        // MARK: Filtre ifadeleri

        mutating func parseLogicalOr() throws -> LogicalExpr {
            var operands = [try parseLogicalAnd()]
            while true {
                skipBlank()
                guard current == "|" else { break }
                guard peek(1) == "|" else { throw error(L10n.t("jsonpath.useOr")) }
                index += 2
                skipBlank()
                operands.append(try parseLogicalAnd())
            }
            return operands.count == 1 ? operands[0] : .or(operands)
        }

        mutating func parseLogicalAnd() throws -> LogicalExpr {
            var operands = [try parseBasic()]
            while true {
                skipBlank()
                guard current == "&" else { break }
                guard peek(1) == "&" else { throw error(L10n.t("jsonpath.useAnd")) }
                index += 2
                skipBlank()
                operands.append(try parseBasic())
            }
            return operands.count == 1 ? operands[0] : .and(operands)
        }

        mutating func parseBasic() throws -> LogicalExpr {
            skipBlank()
            guard let character = current else { throw error(L10n.t("jsonpath.filterIncomplete")) }
            if character == "!" , peek(1) != "=" {
                index += 1
                skipBlank()
                if current == "(" {
                    return .not(try parseParenthesized())
                }
                let start = index
                let operand = try parseComparable()
                guard let test = Self.testOperand(operand) else {
                    throw error(L10n.t("jsonpath.notOperand"), at: start)
                }
                try checkTestFunction(test, at: start)
                return .not(.test(test))
            }
            if character == "(" {
                return try parseParenthesized()
            }
            let start = index
            let left = try parseComparable()
            skipBlank()
            if let op = parseComparisonOperator() {
                skipBlank()
                let rightStart = index
                let right = try parseComparable()
                try checkComparable(left, at: start)
                try checkComparable(right, at: rightStart)
                return .comparison(left, op, right)
            }
            guard let test = Self.testOperand(left) else {
                throw error(L10n.t("jsonpath.literalAlone"), at: start)
            }
            try checkTestFunction(test, at: start)
            return .test(test)
        }

        mutating func parseParenthesized() throws -> LogicalExpr {
            let open = index
            index += 1
            skipBlank()
            let inner = try parseLogicalOr()
            skipBlank()
            guard current == ")" else { throw error(atEnd ? L10n.t("jsonpath.unclosedParen") : L10n.t("jsonpath.expectedParen"), at: atEnd ? open : nil) }
            index += 1
            return inner
        }

        static func testOperand(_ comparable: Comparable) -> TestOperand? {
            switch comparable {
            case .query(let query): return .query(query)
            case .function(let call): return .function(call)
            case .literal: return nil
            }
        }

        /// Değer döndüren işlev (length, count, value) tek başına doğru/yanlış değildir.
        func checkTestFunction(_ test: TestOperand, at position: Int) throws {
            if case .function(let call) = test, ![.match, .search].contains(call.name) {
                throw error(L10n.t("jsonpath.compareValue", call.name.rawValue), at: position)
            }
        }

        func checkComparable(_ comparable: Comparable, at position: Int) throws {
            switch comparable {
            case .query(let query) where !query.isSingular:
                throw error(L10n.t("jsonpath.singular"), at: position)
            case .function(let call) where [.match, .search].contains(call.name):
                throw error(L10n.t("jsonpath.logicalAlone", call.name.rawValue), at: position)
            default:
                return
            }
        }

        mutating func parseComparisonOperator() -> ComparisonOp? {
            for op in [ComparisonOp.eq, .ne, .le, .ge, .lt, .gt] {
                let symbol = Array(op.rawValue)
                if index + symbol.count <= chars.count, Array(chars[index..<index + symbol.count]) == symbol {
                    index += symbol.count
                    return op
                }
            }
            return nil
        }

        mutating func parseComparable() throws -> Comparable {
            guard let character = current else { throw error(L10n.t("jsonpath.expectedOperand")) }
            switch character {
            case "@", "$":
                index += 1
                return .query(FilterQuery(relative: character == "@", segments: try parseSegments(inFilter: true)))
            case "'", "\"":
                return .literal(.string(try parseStringLiteral()))
            default:
                if character == "-" || (character.isASCII && character.isNumber) {
                    return .literal(try parseNumberLiteral())
                }
                if character.isASCII && character.isLetter {
                    let start = index
                    while let next = current, next.isASCII && (next.isLetter || next.isNumber || next == "_") { index += 1 }
                    let word = String(chars[start..<index])
                    skipBlank()
                    if current == "(" {
                        return .function(try parseFunction(named: word, at: start))
                    }
                    switch word {
                    case "true": return .literal(.bool(true))
                    case "false": return .literal(.bool(false))
                    case "null": return .literal(.null)
                    default:
                        throw error(L10n.t("jsonpath.unknownWord", word), at: start)
                    }
                }
                if character == "]" || character == ")" || character == "," {
                    throw error(L10n.t("jsonpath.expectedValue"))
                }
                throw error(L10n.t("jsonpath.unexpectedInFilter", String(character)))
            }
        }

        mutating func parseNumberLiteral() throws -> JSONValue {
            let start = index
            if current == "-" { index += 1 }
            guard let first = current, first.isASCII, first.isNumber else { throw error(L10n.t("jsonpath.expectedNumber"), at: start) }
            if first == "0", let next = peek(1), next.isASCII, next.isNumber {
                throw error(L10n.t("jsonpath.leadingZero"), at: start)
            }
            while let character = current, character.isASCII, character.isNumber { index += 1 }
            if current == ".", let next = peek(1), next.isASCII, next.isNumber {
                index += 1
                while let character = current, character.isASCII, character.isNumber { index += 1 }
            }
            if current == "e" || current == "E" {
                index += 1
                if current == "+" || current == "-" { index += 1 }
                guard let digit = current, digit.isASCII, digit.isNumber else { throw error(L10n.t("json.missingExponent"), at: start) }
                while let character = current, character.isASCII, character.isNumber { index += 1 }
            }
            return .number(String(chars[start..<index]))
        }

        mutating func parseFunction(named word: String, at start: Int) throws -> FunctionCall {
            guard let name = FunctionName(rawValue: word) else {
                throw error(L10n.t("jsonpath.unknownFunction", word), at: start)
            }
            index += 1 // (
            var arguments: [FunctionArgument] = []
            skipBlank()
            if current != ")" {
                while true {
                    skipBlank()
                    let argumentStart = index
                    if current == "!" || current == "(" {
                        arguments.append(.logical(try parseLogicalOr()))
                    } else {
                        switch try parseComparable() {
                        case .literal(let value): arguments.append(.literal(value))
                        case .query(let query): arguments.append(.query(query))
                        case .function(let call): arguments.append(.function(call))
                        }
                    }
                    _ = argumentStart
                    skipBlank()
                    if current == "," { index += 1; continue }
                    if current == ")" { break }
                    throw error(atEnd ? "unclosed \(word)(" : "expected \",\" or \")\" in \(word)(…)")
                }
            }
            index += 1 // )
            let expected = (name == .match || name == .search) ? 2 : 1
            guard arguments.count == expected else {
                throw error(L10n.t("jsonpath.arguments", word, L10n.plural("jsonpath.argumentCount", count: expected), L10n.number(arguments.count)), at: start)
            }
            if name == .count || name == .value, case .literal = arguments[0] {
                throw error(L10n.t("jsonpath.needsQuery", word), at: start)
            }
            var pattern: NSRegularExpressionBox?
            if name == .match || name == .search, case .literal(.string(let regex)) = arguments[1] {
                guard let compiled = Self.regex(regex, anchored: name == .match) else {
                    throw error(L10n.t("jsonpath.badRegex", regex), at: start)
                }
                pattern = NSRegularExpressionBox(compiled)
            }
            return FunctionCall(name: name, arguments: arguments, pattern: pattern)
        }

        /// `match` tüm metni, `search` herhangi bir parçayı eşler. RFC'deki
        /// I-Regexp'te `.` satır sonu dışındaki karakterlerdir; ICU'da da öyle.
        static func regex(_ pattern: String, anchored: Bool) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: anchored ? "^(?:\(pattern))$" : pattern)
        }
    }

    // MARK: - Değerlendirme

    struct Context {
        let root: JSONValue
        var work = 0

        init(root: JSONValue) { self.root = root }

        mutating func spend(_ amount: Int = 1) throws {
            work += amount
            if work > JSONPath.workBudget {
                throw LimitError(message: L10n.t("jsonpath.tooExpensive"))
            }
        }

        mutating func run(_ segments: [Segment], from start: [JSONValue]) throws -> [JSONValue] {
            var nodes = start
            for segment in segments {
                var next: [JSONValue] = []
                for node in nodes {
                    if segment.descendant {
                        for visited in try descendants(of: node) {
                            try select(segment.selectors, on: visited, into: &next)
                        }
                    } else {
                        try select(segment.selectors, on: node, into: &next)
                    }
                    if next.count > JSONPath.maxMatches {
                        throw LimitError(message: L10n.t("jsonpath.tooManyMatches", L10n.number(JSONPath.maxMatches)))
                    }
                }
                nodes = next
            }
            return nodes
        }

        /// Düğümün kendisi ve tüm alt düğümleri, belge sırasıyla (önce düğüm,
        /// sonra çocukları). Yığınla: derin belgede özyineleme taşmasın.
        mutating func descendants(of node: JSONValue) throws -> [JSONValue] {
            var result: [JSONValue] = []
            var stack = [node]
            while let next = stack.popLast() {
                try spend()
                result.append(next)
                switch next {
                case .object(let members): stack.append(contentsOf: members.reversed().map(\.value))
                case .array(let items): stack.append(contentsOf: items.reversed())
                default: break
                }
            }
            return result
        }

        mutating func select(_ selectors: [Selector], on node: JSONValue, into out: inout [JSONValue]) throws {
            for selector in selectors {
                try spend()
                switch selector {
                case .name(let name):
                    if case .object(let members) = node, let member = members.first(where: { $0.key == name }) {
                        out.append(member.value)
                    }
                case .wildcard:
                    switch node {
                    case .object(let members): out.append(contentsOf: members.map(\.value))
                    case .array(let items): out.append(contentsOf: items)
                    default: break
                    }
                case .index(let position):
                    if case .array(let items) = node {
                        let resolved = position < 0 ? items.count + position : position
                        if items.indices.contains(resolved) { out.append(items[resolved]) }
                    }
                case .slice(let start, let end, let step):
                    if case .array(let items) = node {
                        for position in Self.sliceIndices(count: items.count, start: start, end: end, step: step) {
                            out.append(items[position])
                        }
                    }
                case .filter(let expression):
                    let children: [JSONValue]
                    switch node {
                    case .object(let members): children = members.map(\.value)
                    case .array(let items): children = items
                    default: children = []
                    }
                    for child in children where try evaluate(expression, current: child) {
                        out.append(child)
                    }
                }
            }
        }

        /// RFC 9535 §2.3.4.2.2 dilim kuralı.
        static func sliceIndices(count: Int, start: Int?, end: Int?, step: Int?) -> [Int] {
            let step = step ?? 1
            guard step != 0, count > 0 else { return [] }
            func normalize(_ value: Int) -> Int { value >= 0 ? value : count + value }
            var result: [Int] = []
            if step > 0 {
                let lower = min(max(normalize(start ?? 0), 0), count)
                let upper = min(max(normalize(end ?? count), 0), count)
                var position = lower
                while position < upper { result.append(position); position += step }
            } else {
                let upper = min(max(normalize(start ?? count - 1), -1), count - 1)
                let lower = min(max(end.map(normalize) ?? -1, -1), count - 1)
                var position = upper
                while lower < position { result.append(position); position += step }
            }
            return result
        }

        // MARK: Filtre

        mutating func evaluate(_ expression: LogicalExpr, current: JSONValue) throws -> Bool {
            switch expression {
            case .or(let operands):
                for operand in operands where try evaluate(operand, current: current) { return true }
                return false
            case .and(let operands):
                for operand in operands where !(try evaluate(operand, current: current)) { return false }
                return true
            case .not(let inner):
                return !(try evaluate(inner, current: current))
            case .test(.query(let query)):
                return !(try nodes(of: query, current: current)).isEmpty
            case .test(.function(let call)):
                return try logical(call, current: current)
            case .comparison(let left, let op, let right):
                return Self.compare(try value(of: left, current: current), op, try value(of: right, current: current))
            }
        }

        mutating func nodes(of query: FilterQuery, current: JSONValue) throws -> [JSONValue] {
            try run(query.segments, from: [query.relative ? current : root])
        }

        /// Karşılaştırma operandı: değer ya da "hiçbir şey" (`nil`).
        mutating func value(of comparable: Comparable, current: JSONValue) throws -> JSONValue? {
            switch comparable {
            case .literal(let value): return value
            case .query(let query):
                let found = try nodes(of: query, current: current)
                return found.count == 1 ? found[0] : nil
            case .function(let call): return try functionValue(call, current: current)
            }
        }

        mutating func argumentValue(_ argument: FunctionArgument, current: JSONValue) throws -> JSONValue? {
            switch argument {
            case .literal(let value): return value
            case .query(let query):
                let found = try nodes(of: query, current: current)
                return found.count == 1 ? found[0] : nil
            case .function(let call): return try functionValue(call, current: current)
            case .logical: return nil
            }
        }

        mutating func functionValue(_ call: FunctionCall, current: JSONValue) throws -> JSONValue? {
            switch call.name {
            case .length:
                switch try argumentValue(call.arguments[0], current: current) {
                case .string(let text): return .number(String(text.unicodeScalars.count))
                case .array(let items): return .number(String(items.count))
                case .object(let members): return .number(String(members.count))
                default: return nil
                }
            case .count:
                guard case .query(let query) = call.arguments[0] else { return nil }
                return .number(String(try nodes(of: query, current: current).count))
            case .value:
                guard case .query(let query) = call.arguments[0] else { return nil }
                let found = try nodes(of: query, current: current)
                return found.count == 1 ? found[0] : nil
            case .match, .search:
                return nil
            }
        }

        mutating func logical(_ call: FunctionCall, current: JSONValue) throws -> Bool {
            guard call.name == .match || call.name == .search,
                  case .string(let text)? = try argumentValue(call.arguments[0], current: current) else { return false }
            let regex: NSRegularExpression
            if let compiled = call.pattern {
                regex = compiled.regex
            } else {
                guard case .string(let pattern)? = try argumentValue(call.arguments[1], current: current),
                      let compiled = Parser.regex(pattern, anchored: call.name == .match) else { return false }
                regex = compiled
            }
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, range: range) != nil
        }

        /// RFC 9535 §2.3.5.2.2: farklı türler eşit değildir; sıralama yalnızca
        /// sayı-sayı ve metin-metin; "hiçbir şey" yalnızca kendisine eşittir.
        static func compare(_ left: JSONValue?, _ op: ComparisonOp, _ right: JSONValue?) -> Bool {
            switch op {
            case .eq: return equal(left, right)
            case .ne: return !equal(left, right)
            case .lt: return less(left, right)
            case .le: return less(left, right) || equal(left, right)
            case .gt: return less(right, left)
            case .ge: return less(right, left) || equal(left, right)
            }
        }

        static func equal(_ left: JSONValue?, _ right: JSONValue?) -> Bool {
            switch (left, right) {
            case (nil, nil): return true
            case (nil, _), (_, nil): return false
            case let (.number(a)?, .number(b)?): return decimal(a) == decimal(b)
            case let (.object(a)?, .object(b)?):
                guard a.count == b.count else { return false }
                return a.allSatisfy { member in b.contains { $0.key == member.key && equal(member.value, $0.value) } }
            case let (.array(a)?, .array(b)?):
                return a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
            case let (a?, b?): return a == b
            }
        }

        static func less(_ left: JSONValue?, _ right: JSONValue?) -> Bool {
            switch (left, right) {
            case let (.number(a)?, .number(b)?):
                guard let x = decimal(a), let y = decimal(b) else { return false }
                return x < y
            case let (.string(a)?, .string(b)?):
                return a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
            default:
                return false
            }
        }

        static func decimal(_ raw: String) -> Decimal? {
            Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
        }
    }
}
