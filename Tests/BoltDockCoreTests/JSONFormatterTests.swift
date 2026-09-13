import XCTest
@testable import BoltDockCore

final class JSONFormatterTests: XCTestCase {
    func testBeautifiesCompactObject() throws {
        let result = try JSONFormatter.beautify(#"{"a":1,"b":"x"}"#)
        XCTAssertEqual(result, """
        {
          "a": 1,
          "b": "x"
        }
        """)
    }

    func testPreservesKeyOrder() throws {
        let result = try JSONFormatter.beautify(#"{"zebra":1,"alpha":2}"#)
        let zebraIndex = result.range(of: "zebra")!.lowerBound
        let alphaIndex = result.range(of: "alpha")!.lowerBound
        XCTAssertLessThan(zebraIndex, alphaIndex)
    }

    func testNestedStructures() throws {
        let result = try JSONFormatter.beautify(#"{"list":[1,2],"obj":{"k":"v"}}"#)
        XCTAssertEqual(result, """
        {
          "list": [
            1,
            2
          ],
          "obj": {
            "k": "v"
          }
        }
        """)
    }

    func testEmptyContainersStayCompact() throws {
        XCTAssertEqual(try JSONFormatter.beautify("{}"), "{}")
        XCTAssertEqual(try JSONFormatter.beautify(#"{"a":[],"b":{}}"#), """
        {
          "a": [],
          "b": {}
        }
        """)
    }

    func testStringContentUntouched() throws {
        // String içindeki {,:" gibi karakterler biçimlendirmeyi bozmamalı.
        let result = try JSONFormatter.beautify(#"{"a":"x{,}: \" y"}"#)
        XCTAssertTrue(result.contains(#""x{,}: \" y""#))
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try JSONFormatter.beautify(#"{"a":}"#))
        XCTAssertThrowsError(try JSONFormatter.beautify("merhaba"))
        XCTAssertThrowsError(try JSONFormatter.beautify(""))
        XCTAssertThrowsError(try JSONFormatter.beautify("   "))
    }

    func testFragmentAllowed() throws {
        // Tek değerlik JSON fragment'ları (sayı, string) geçerli sayılır.
        XCTAssertEqual(try JSONFormatter.beautify("42"), "42")
    }
}
