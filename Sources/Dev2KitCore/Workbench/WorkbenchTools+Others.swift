import Foundation

extension WorkbenchTools {
    /// JSONPath sorgusu (RFC 9535): girdi JSON, sorgu satırı, sonuç eşleşen
    /// değerlerin biçimli JSON dizisi. Kural ve sınırlar `JSONPath`'te.
    public static let jsonPath = WorkbenchTool(
        id: "jsonpath",
        title: "JSONPath",
        inputName: "JSON",
        category: .others,
        keywords: ["jsonpath", "query", "filter", "select", "path", "sorgu", "filtre"],
        syntax: .json,
        actions: [
            WorkbenchAction(id: "query", title: "Query", usesIndentation: true, usesQuery: true) { input, options in
                try JSONPathTool.run(input, options: options)
            },
        ],
        validate: { JSONTool.validate($0) },
        defaultOptions: WorkbenchOptions(query: "$"),
        sampleInput: JSONPathTool.sample,
        sampleOptions: { $0.query = JSONPathTool.sampleQuery },
        inputFormatter: { input, options in try JSONTool.format(input, options: options) }
    )
}

public enum JSONPathTool {
    /// RFC 9535'teki kitapçı örneği (herkese açık, gerçek veri değil).
    public static let sample = """
    {
      "store": {
        "book": [
          { "category": "reference", "author": "Nigel Rees", "title": "Sayings of the Century", "price": 8.95 },
          { "category": "fiction", "author": "Herman Melville", "title": "Moby Dick", "isbn": "0-553-21311-3", "price": 8.99 },
          { "category": "fiction", "author": "J. R. R. Tolkien", "title": "The Lord of the Rings", "isbn": "0-395-19395-8", "price": 22.99 }
        ],
        "bicycle": { "color": "red", "price": 399 }
      }
    }
    """
    public static let sampleQuery = "$.store.book[?@.price < 10].title"

    /// Eşleşen değerler biçimli JSON dizisi olarak; özet eşleşme sayısı.
    /// Eşleşme yoksa `[]` ve "No matches" (hata değil). JSON hatası girdide
    /// konumlu (`WorkbenchIssue`), sorgu hatası sütunlu (`JSONPath.QueryError`).
    public static func run(_ input: String, options: WorkbenchOptions) throws -> WorkbenchRunResult {
        let root = try JSONDocument.parse(input)
        let matches = try JSONPath.evaluate(options.query, on: root)
        let output = try JSONFormatter.beautify(JSONValue.array(matches).compact(), indent: options.indentation.unit)
        return WorkbenchRunResult(output: output, summary: summary(count: matches.count))
    }

    public static func summary(count: Int) -> String {
        switch count {
        case 0: return L10n.t("jsonpath.noMatches")
        default: return L10n.plural("jsonpath.matches", count: count)
        }
    }
}
