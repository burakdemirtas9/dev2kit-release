import XCTest
@testable import Dev2KitCore

final class SQLFormatterTests: XCTestCase {
    func testBasicQueryLayout() throws {
        let result = try SQLFormatter.beautify("select a, b.c as x from t join u on u.id = t.u_id where x = 1 and y between 1 and 2 order by a desc")
        XCTAssertEqual(result, """
        SELECT
          a,
          b.c AS x
        FROM t
        JOIN u ON u.id = t.u_id
        WHERE x = 1
          AND y BETWEEN 1 AND 2
        ORDER BY
          a DESC
        """)
    }

    func testSubqueryIsIndented() throws {
        let result = try SQLFormatter.beautify("SELECT * FROM t WHERE id IN (SELECT id FROM u WHERE z = 'a')")
        XCTAssertEqual(result, """
        SELECT
          *
        FROM t
        WHERE id IN (
          SELECT
            id
          FROM u
          WHERE z = 'a'
        )
        """)
    }

    func testStringsIdentifiersAndCommentsAreUntouched() throws {
        let result = try SQLFormatter.beautify("select 'it''s, from' as \"Select\", [order], `x` -- not, from\nfrom t /* where */")
        XCTAssertTrue(result.contains("'it''s, from' AS \"Select\""), result)
        XCTAssertTrue(result.contains("[order]"), result)
        XCTAssertTrue(result.contains("-- not, from"), result)
        XCTAssertTrue(result.contains("/* where */"), result)
        // Ters bölü SQL'de kaçış değil.
        XCTAssertTrue(try SQLFormatter.beautify("select 'C:\\' from t").contains("'C:\\'"))
    }

    func testFunctionsWindowsAndJoinsStayReadable() throws {
        let result = try SQLFormatter.beautify("select count(*), row_number() over (partition by a order by b) from t left outer join u on 1=1")
        XCTAssertTrue(result.contains("COUNT(*),"), result)
        XCTAssertTrue(result.contains("OVER (PARTITION BY a ORDER BY b)"), "pencere ifadesi bölünmemeli: \(result)")
        XCTAssertTrue(result.contains("\nLEFT OUTER JOIN u ON 1 = 1"), result)
    }

    func testKeywordCaseIsOptional() throws {
        XCTAssertEqual(try SQLFormatter.beautify("select a from t", uppercaseKeywords: false), "select\n  a\nfrom t")
    }

    func testStatementsAreSeparatedAndParametersKept() throws {
        let result = try SQLFormatter.beautify("update t set a = :yeni, b = @p where id = $1; delete from t where x::int > 2")
        XCTAssertTrue(result.contains("UPDATE t\nSET\n  a = :yeni,\n  b = @p\nWHERE id = $1;\n\nDELETE FROM t"), result)
        XCTAssertTrue(result.contains("x::int > 2"), result)
    }

    func testUnbalancedInputThrows() {
        XCTAssertThrowsError(try SQLFormatter.beautify("select (a from t"))
        XCTAssertThrowsError(try SQLFormatter.beautify("select 'açık from t"))
    }

    func testMinify() throws {
        XCTAssertEqual(try SQLFormatter.minify("SELECT a ,  b -- yorum\nFROM  t\nWHERE x = 'a  b' /* c */ AND y IN ( 1 , 2 );"),
                       "SELECT a,b FROM t WHERE x='a  b' AND y IN(1,2);")
    }
}
