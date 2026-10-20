import XCTest
@testable import Dev2KitCore

/// JSONPath (RFC 9535). Örnek veri RFC'deki kitapçı belgesi (herkese açık
/// örnek, gerçek veri değil).
final class JSONPathTests: XCTestCase {
    /// Beklenen mesajlar İngilizce.
    override func invokeTest() { withLanguage(.english) { super.invokeTest() } }

    private let store = """
    { "store": {
        "book": [
          { "category": "reference", "author": "Nigel Rees", "title": "Sayings of the Century", "price": 8.95 },
          { "category": "fiction", "author": "Evelyn Waugh", "title": "Sword of Honour", "price": 12.99 },
          { "category": "fiction", "author": "Herman Melville", "title": "Moby Dick", "isbn": "0-553-21311-3", "price": 8.99 },
          { "category": "fiction", "author": "J. R. R. Tolkien", "title": "The Lord of the Rings", "isbn": "0-395-19395-8", "price": 22.99 }
        ],
        "bicycle": { "color": "red", "price": 399 }
      }
    }
    """

    private func run(_ query: String, on json: String? = nil) throws -> [String] {
        try JSONPath.evaluate(query, on: JSONDocument.parse(json ?? store)).map { $0.compact() }
    }

    private func queryError(_ query: String, on json: String = "{}") -> JSONPath.QueryError? {
        do {
            _ = try JSONPath.evaluate(query, on: JSONDocument.parse(json))
            return nil
        } catch let error as JSONPath.QueryError {
            return error
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
            return nil
        }
    }

    // MARK: - RFC örnekleri

    func testRootChildAndWildcard() throws {
        XCTAssertEqual(try run("$.store.book[*].author"),
                       [#""Nigel Rees""#, #""Evelyn Waugh""#, #""Herman Melville""#, #""J. R. R. Tolkien""#])
        XCTAssertEqual(try run("$.store.*").count, 2)
        XCTAssertEqual(try run("$").count, 1)
    }

    func testRecursiveDescent() throws {
        XCTAssertEqual(try run("$..author").count, 4)
        XCTAssertEqual(try run("$.store..price"), ["8.95", "12.99", "8.99", "22.99", "399"])
        XCTAssertEqual(try run("$..*").count, 27)
    }

    func testIndicesUnionAndSlices() throws {
        XCTAssertEqual(try run("$..book[2].title"), [#""Moby Dick""#])
        XCTAssertEqual(try run("$..book[-1].title"), [#""The Lord of the Rings""#])
        XCTAssertEqual(try run("$..book[0,1].title").count, 2)
        XCTAssertEqual(try run("$..book[:2].title").count, 2)
        XCTAssertEqual(try run("$..book[9]"), [], "olmayan indeks hata değil, eşleşme yok")
    }

    func testFilters() throws {
        XCTAssertEqual(try run("$..book[?@.isbn].title"), [#""Moby Dick""#, #""The Lord of the Rings""#])
        XCTAssertEqual(try run("$..book[?@.price<10].title"), [#""Sayings of the Century""#, #""Moby Dick""#])
        XCTAssertEqual(try run("$..book[?(@.price < 10)].title").count, 2, "Goessner tarzı parantez de geçerli")
        XCTAssertEqual(try run("$..book[?@.price > 10 && @.category == 'fiction'].title").count, 2)
        XCTAssertEqual(try run("$..book[?@.category == 'reference' || @.price > 20].title").count, 2)
        XCTAssertEqual(try run("$..book[?!@.isbn].title").count, 2)
        XCTAssertEqual(try run("$..book[?@.price < $.store.bicycle.price]").count, 4, "$ filtrede kök")
        XCTAssertEqual(try run("$..book[?@.price == 99]"), [], "eşleşme yok")
    }

    func testFunctions() throws {
        XCTAssertEqual(try run("$..book[?length(@.title) > 15].title").count, 2)
        XCTAssertEqual(try run("$.store[?count(@.*) == 2]").count, 1, "yalnızca bicycle'ın 2 üyesi var")
        XCTAssertEqual(try run("$..book[?match(@.author, 'Herman.*')].title"), [#""Moby Dick""#])
        XCTAssertEqual(try run("$..book[?search(@.title, 'of')].title").count, 3)
        XCTAssertEqual(try run("$.store[?value(@..color) == 'red']").count, 1)
    }

    // MARK: - Dilim kuralı (RFC 9535 §2.3.4)

    func testSliceSemantics() throws {
        let digits = "[0,1,2,3,4,5,6,7,8,9]"
        XCTAssertEqual(try run("$[1:3]", on: digits), ["1", "2"])
        XCTAssertEqual(try run("$[5:]", on: digits), ["5", "6", "7", "8", "9"])
        XCTAssertEqual(try run("$[::3]", on: digits), ["0", "3", "6", "9"])
        XCTAssertEqual(try run("$[::-1]", on: digits).first, "9")
        XCTAssertEqual(try run("$[5:1:-2]", on: digits), ["5", "3"])
        XCTAssertEqual(try run("$[-2:]", on: digits), ["8", "9"])
        XCTAssertEqual(try run("$[::0]", on: digits), [], "adım 0: boş")
    }

    // MARK: - Özel anahtarlar, null, türler

    func testSpecialKeys() throws {
        let json = #"{"a.b": 1, "content-type": "json", "it's": 2, "q\"t": 3, "çay": 4, " ": 5}"#
        XCTAssertEqual(try run("$['a.b']", on: json), ["1"])
        XCTAssertEqual(try run(#"$["content-type"]"#, on: json), [#""json""#])
        XCTAssertEqual(try run(#"$['it\'s']"#, on: json), ["2"])
        XCTAssertEqual(try run(#"$["q\"t"]"#, on: json), ["3"])
        XCTAssertEqual(try run("$.çay", on: json), ["4"], "ASCII dışı ad kısayolda geçerli")
        XCTAssertEqual(try run(#"$['çay']"#, on: json), ["4"])
        XCTAssertEqual(try run("$[' ']", on: json), ["5"])
    }

    func testNullIsAMatchNotAnEmptyResult() throws {
        let json = #"{"a": null, "list": [{"x": null}, {"x": 1}, {}]}"#
        XCTAssertEqual(try run("$.a", on: json), ["null"])
        XCTAssertEqual(try run("$.missing", on: json), [])
        XCTAssertEqual(try run("$.list[?@.x == null]", on: json), [#"{"x":null}"#], "eksik alan null'a eşit değil")
        XCTAssertEqual(try run("$.list[?@.x]", on: json).count, 2, "null değerli alan vardır")
    }

    func testComparisonAcrossTypesAndNothing() throws {
        let json = #"[{"a": 1, "b": "1"}, {"a": 1, "b": 1.0}, {}]"#
        XCTAssertEqual(try run("$[?@.a == @.b]", on: json), [#"{"a":1,"b":1.0}"#, "{}"], "1 == 1.0; hiçbir şey == hiçbir şey")
        XCTAssertEqual(try run("$[?@.a < 'z']", on: json), [], "sayı ile metin sıralanmaz")
        XCTAssertEqual(try run(#"$[?@.b == "1"]"#, on: json).count, 1)
    }

    func testNestedObjectsAndArrays() throws {
        let json = #"{"orders": [{"id": 1, "lines": [{"sku": "A", "qty": 2}, {"sku": "B", "qty": 0}]}, {"id": 2, "lines": []}]}"#
        XCTAssertEqual(try run("$.orders[*].lines[?@.qty > 0].sku", on: json), [#""A""#])
        XCTAssertEqual(try run("$.orders[?length(@.lines) == 0].id", on: json), ["2"])
        XCTAssertEqual(try run("$..sku", on: json), [#""A""#, #""B""#])
    }

    // MARK: - Hatalar (sütunlu, anlaşılır)

    func testQueryErrorsExplainAndLocate() {
        XCTAssertEqual(queryError("")?.message, "the query is empty; start with $")
        XCTAssertEqual(queryError("store.book")?.column, 1)
        XCTAssertTrue(queryError("@.a")?.message.contains("@ is only valid inside a filter") == true)
        let hyphen = queryError("$.content-type")
        XCTAssertEqual(hyphen?.column, 10)
        XCTAssertTrue(hyphen?.message.contains("['content-type']") == true)
        XCTAssertTrue(queryError("$[(@.length-1)]")?.message.contains("script expressions") == true)
        XCTAssertEqual(queryError("$['a'")?.column, 2, "kapanmamış [ açıldığı yerde")
        XCTAssertTrue(queryError("$[01]")?.message.contains("leading zeros") == true)
        XCTAssertTrue(queryError("$[-0]")?.message.contains("-0") == true)
        let incomplete = queryError("$[?@.price <]")
        XCTAssertTrue(incomplete?.message.contains("expected a value") == true, "\(String(describing: incomplete))")
        XCTAssertTrue(queryError("$[?foo(@)]")?.message.contains("unknown function") == true)
        XCTAssertTrue(queryError("$[?@.* == 1]")?.message.contains("single-value") == true)
        XCTAssertTrue(queryError("$[?1]")?.message.contains("must be compared") == true)
        XCTAssertTrue(queryError("$[?length(@.a)]")?.message.contains("returns a value") == true)
        XCTAssertTrue(queryError("$[?match(@.a, '[')]")?.message.contains("invalid regular expression") == true)
        XCTAssertTrue(queryError("$[a]")?.message.contains("must be quoted") == true)
        XCTAssertTrue(queryError("$.a b")?.message.contains("unexpected") == true)
        XCTAssertTrue(queryError("$[?@.a = 1]") != nil, "= tek başına operatör değil")
    }

    func testTooManyMatchesIsALimitNotACrash() throws {
        let big = "[" + Array(repeating: "0", count: JSONPath.maxMatches + 1).joined(separator: ",") + "]"
        XCTAssertThrowsError(try JSONPath.evaluate("$[*]", on: JSONDocument.parse(big))) {
            XCTAssertTrue($0 is JSONPath.LimitError)
        }
    }
}
