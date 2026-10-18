import Foundation

/// JSON'da anlamsal fark: anahtar sırası ve biçim yok sayılır, yalnızca
/// değer farkları yollarıyla listelenir. Yol Token Factory sözdiziminde
/// (`data.items[0].token`) — `JSONTreeNode` ile aynı yazım.
///
/// - Diziler SIRAYA göre karşılaştırılır (eleman eşleştirme yok): en
///   öngörülebilir davranış; araya eleman girince kalanlar "değişti" görünür.
/// - Sayılar DEĞER olarak karşılaştırılır (`1.0` = `1`, `1e2` = `100`);
///   `Decimal` ile, büyük sayılar (`12345678901234567890`) kaybolmaz.
public struct JSONChange: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case added(JSONValue)
        case removed(JSONValue)
        case changed(from: JSONValue, to: JSONValue)
    }

    public let path: String
    public let kind: Kind
    public var id: String { path }

    public static func changes(_ left: JSONValue, _ right: JSONValue) -> [JSONChange] {
        var result: [JSONChange] = []
        compare(left, right, path: "", into: &result)
        return result
    }

    private static func compare(_ left: JSONValue, _ right: JSONValue, path: String, into result: inout [JSONChange]) {
        switch (left, right) {
        case let (.object(a), .object(b)):
            let rightByKey = Dictionary(b.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            let leftKeys = Set(a.map(\.key))
            for member in a {
                let childPath = JSONTreeNode.join(path, key: member.key)
                if let other = rightByKey[member.key] {
                    compare(member.value, other, path: childPath, into: &result)
                } else {
                    result.append(JSONChange(path: childPath, kind: .removed(member.value)))
                }
            }
            for member in b where !leftKeys.contains(member.key) {
                result.append(JSONChange(path: JSONTreeNode.join(path, key: member.key), kind: .added(member.value)))
            }
        case let (.array(a), .array(b)):
            for index in 0..<max(a.count, b.count) {
                let childPath = "\(path)[\(index)]"
                switch (index < a.count ? a[index] : nil, index < b.count ? b[index] : nil) {
                case let (l?, r?): compare(l, r, path: childPath, into: &result)
                case let (l?, nil): result.append(JSONChange(path: childPath, kind: .removed(l)))
                case let (nil, r?): result.append(JSONChange(path: childPath, kind: .added(r)))
                default: break
                }
            }
        case let (.number(a), .number(b)):
            if a != b, Decimal(string: a) != Decimal(string: b) || Decimal(string: a) == nil {
                result.append(JSONChange(path: path, kind: .changed(from: left, to: right)))
            }
        default:
            if left != right { result.append(JSONChange(path: path, kind: .changed(from: left, to: right))) }
        }
    }
}

/// Diff Checker: iki metni (isteğe bağlı) ilgili dilin biçimlendiricisinden
/// geçirip satır satır karşılaştırır; JSON'da ayrıca anlamsal fark listesi.
public enum DiffChecker {
    public enum Language: String, CaseIterable, Identifiable, Sendable {
        case json, xml, html, css, sql, markdown, text
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .json: return "JSON"
            case .xml: return "XML"
            case .html: return "HTML"
            case .css: return "CSS"
            case .sql: return "SQL"
            case .markdown: return "Markdown"
            case .text: return "Text"
            }
        }

        public var syntax: Beautifier.Kind {
            switch self {
            case .json: return .json
            case .xml: return .xml
            case .html: return .html
            case .css: return .css
            case .sql: return .sql
            case .markdown: return .markdown
            case .text: return .plain
            }
        }

        /// Karşılaştırmadan önceki biçimlendirme. JSON'da anahtarlar da
        /// sıralanır: anahtar sırası anlam taşımaz, satır farkında gürültü olmasın.
        func normalize(_ text: String) throws -> String {
            switch self {
            case .json: return try JSONTool.format(text, options: WorkbenchOptions(sortKeys: true))
            case .text: return text
            default: return try Beautifier.beautify(text, as: syntax)
            }
        }
    }

    public struct Options: Hashable, Sendable {
        public var normalize: Bool
        public var line: LineDiff.Options

        public init(normalize: Bool = true, line: LineDiff.Options = .init()) {
            self.normalize = normalize
            self.line = line
        }
    }

    public struct Result: Sendable {
        public let rows: [DiffRow]
        public let changeStarts: [Int]
        public let added: Int
        public let removed: Int
        /// Yalnızca JSON'da ve iki taraf da geçerliyse.
        public let jsonChanges: [JSONChange]?
        /// Biçimlendirilemeyen taraf: olduğu gibi karşılaştırıldı.
        public let leftIssue: String?
        public let rightIssue: String?
        public let isSimplified: Bool

        public var isIdentical: Bool { added == 0 && removed == 0 && (jsonChanges?.isEmpty ?? true) }
    }

    public static func compare(_ left: String, _ right: String, language: Language, options: Options = .init()) -> Result {
        func prepared(_ text: String) -> (text: String, issue: String?) {
            guard options.normalize, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (text, nil) }
            do { return (try language.normalize(text), nil) } catch { return (text, error.localizedDescription) }
        }
        let l = prepared(left)
        let r = prepared(right)
        let leftLines = splitLines(l.text)
        let rightLines = splitLines(r.text)
        let diff = LineDiff.diff(leftLines, rightLines, options: options.line)
        let rows = DiffRow.rows(diff.operations, left: leftLines, right: rightLines)

        var jsonChanges: [JSONChange]?
        if language == .json, let a = try? JSONDocument.parse(left), let b = try? JSONDocument.parse(right) {
            jsonChanges = JSONChange.changes(a, b)
        }
        return Result(
            rows: rows,
            changeStarts: DiffRow.changeStarts(rows),
            added: rows.filter { $0.kind == .added || $0.kind == .changed }.count,
            removed: rows.filter { $0.kind == .removed || $0.kind == .changed }.count,
            jsonChanges: jsonChanges,
            leftIssue: l.issue,
            rightIssue: r.issue,
            isSimplified: diff.isSimplified
        )
    }

    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
