import XCTest
@testable import Dev2KitCore

/// JSON → sınıf/tip üretimi (Object Converter, 2026-10-20).
final class ObjectCodeGeneratorTests: XCTestCase {
    private let sample = """
    {
      "id": 42,
      "customer_name": "Ada",
      "total": 12.5,
      "big": 9000000000,
      "active": true,
      "note": null,
      "address": { "city": "İstanbul", "zip": "34000" },
      "items": [
        { "sku": "A1", "qty": 1 },
        { "sku": "B2", "qty": 2, "gift": true }
      ],
      "tags": ["a", "b"]
    }
    """

    private func generate(_ language: ObjectCodeGenerator.Language, _ json: String? = nil) throws -> String {
        try ObjectCodeGenerator.generate(json ?? sample, language: language)
    }

    func testJavaLombokWithNestedNumberedClasses() throws {
        XCTAssertEqual(try generate(.java), """
        import java.util.List;
        import lombok.AllArgsConstructor;
        import lombok.Data;
        import lombok.NoArgsConstructor;

        @Data
        @NoArgsConstructor
        @AllArgsConstructor
        public class Root {
            private Integer id;
            private String customer_name;
            private Double total;
            private Long big;
            private Boolean active;
            private Object note;
            private Object1 address;
            private List<Object2> items;
            private List<String> tags;

            @Data
            @NoArgsConstructor
            @AllArgsConstructor
            public static class Object1 {
                private String city;
                private String zip;
            }

            @Data
            @NoArgsConstructor
            @AllArgsConstructor
            public static class Object2 {
                private String sku;
                private Integer qty;
                private Boolean gift;
            }
        }
        """)
    }

    func testKotlinOptionalsAndInvalidKeysGetMapping() throws {
        let out = try generate(.kotlin, #"{ "Content-Type": "x", "class": 1, "list": [{ "a": 1 }, {}] }"#)
        XCTAssertEqual(out, """
        import com.fasterxml.jackson.annotation.JsonProperty

        data class Root(
            @JsonProperty("Content-Type") val Content_Type: String,
            @JsonProperty("class") val class_: Int,
            val list: List<Object1>,
        )

        data class Object1(
            val a: Int? = null,
        )
        """)
    }

    func testSwiftCodingKeysOnlyWhenNeededAndAnyHelper() throws {
        let out = try generate(.swift, #"{ "id": 1, "Content-Type": "x", "default": true, "misc": [1, "a"] }"#)
        XCTAssertTrue(out.contains("let `default`: Bool"), out)
        XCTAssertTrue(out.contains("case Content_Type = \"Content-Type\""), out)
        XCTAssertTrue(out.contains("let misc: [JSONValue]"), out)
        XCTAssertTrue(out.contains("enum JSONValue: Codable"), out)
        let plain = try generate(.swift, #"{ "id": 1 }"#)
        XCTAssertEqual(plain, "struct Root: Codable {\n    let id: Int\n}")
    }

    func testTypeScriptInterfaceAndType() throws {
        let json = #"[{ "id": 1, "name": null, "Content-Type": "x" }, { "id": 2, "name": "b" , "extra": [] }]"#
        XCTAssertEqual(try generate(.typeScriptInterface, json), """
        export interface Root {
          id: number;
          name: string | null;
          "Content-Type"?: string;
          extra?: unknown[];
        }
        """)
        XCTAssertTrue(try generate(.typeScriptType, json).hasPrefix("export type Root = {"))
    }

    func testPythonDataclassOrdersDefaultsLast() throws {
        let out = try generate(.python, #"{ "note": null, "id": 1, "from": "x" }"#)
        XCTAssertEqual(out, """
        from __future__ import annotations

        from dataclasses import dataclass
        from typing import Any, Optional


        @dataclass
        class Root:
            id: int
            from_: str  # JSON: "from"
            note: Optional[Any] = None
        """)
    }

    func testIdenticalShapesShareOneType() throws {
        let out = try generate(.typeScriptInterface, #"{ "from": { "lat": 1.5, "lng": 2.5 }, "to": { "lat": 3.5, "lng": 4.5 } }"#)
        XCTAssertTrue(out.contains("from: Object1;") && out.contains("to: Object1;"), out)
        XCTAssertFalse(out.contains("Object2"))
    }

    func testRejectsNonObjectRootAndTooDeep() {
        XCTAssertThrowsError(try generate(.java, "[1, 2]")) { XCTAssertEqual($0 as? ObjectCodeGenerator.GenerateError, .rootNotObject) }
        XCTAssertThrowsError(try generate(.java, "\"x\""))
        let deep = String(repeating: #"{"a":"#, count: 40) + "1" + String(repeating: "}", count: 40)
        XCTAssertThrowsError(try generate(.java, deep)) {
            XCTAssertEqual($0 as? ObjectCodeGenerator.GenerateError, .tooDeep(ObjectCodeGenerator.maxDepth))
        }
    }
}
