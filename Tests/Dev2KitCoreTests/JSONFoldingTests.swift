import XCTest
@testable import Dev2KitCore

final class JSONFoldingTests: XCTestCase {
    private func text(_ lines: String...) -> String {
        lines.joined(separator: "\n")
    }

    func testObjectSpanningLinesIsFoldable() {
        let json = text("{", "  \"a\": 1", "}")
        let regions = JSONFolding.regions(in: json)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.openLine, 0)
        XCTAssertEqual(regions.first?.closeLine, 2)
        XCTAssertEqual(regions.first?.kind, .object)
    }

    func testSingleLineObjectIsNotFoldable() {
        // Katlamanın kazancı yok.
        XCTAssertTrue(JSONFolding.regions(in: "{\"a\": 1}").isEmpty)
    }

    func testNestedRegionsAreAllReported() {
        let json = text("{", "  \"list\": [", "    1,", "    2", "  ]", "}")
        let regions = JSONFolding.regions(in: json)
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions.map(\.kind), [.object, .array])
        XCTAssertEqual(regions.first?.openLine, 0)
        XCTAssertEqual(regions.last?.openLine, 1)
    }

    func testBracketsInsideStringsAreIgnored() {
        // Değerin içindeki parantez katlama bölgesi değildir.
        let json = text("{", "  \"sablon\": \"{{degisken}}\",", "  \"dizi\": \"[1,2]\"", "}")
        let regions = JSONFolding.regions(in: json)
        XCTAssertEqual(regions.count, 1, "yalnızca dış nesne katlanmalı: \(regions)")
    }

    func testEscapedQuoteDoesNotEndString() {
        let json = text("{", "  \"a\": \"kaçış \\\" { içeride\",", "  \"b\": 1", "}")
        XCTAssertEqual(JSONFolding.regions(in: json).count, 1)
    }

    func testHiddenRangeKeepsBracketsAndClosingLineVisible() {
        // Açılış parantezi ve kapanış SATIRI görünür kalmalı: blok nerede
        // başlıyor, nerede bitiyor okunabilsin.
        let json = text("{", "  \"a\": 1", "}")
        let region = JSONFolding.regions(in: json)[0]
        let nsText = json as NSString
        XCTAssertEqual(nsText.substring(with: NSRange(location: region.hiddenRange.location - 1, length: 1)), "{")
        // Gizli aralık, kapanış satırından önceki satır sonunda biter.
        let afterHidden = region.hiddenRange.location + region.hiddenRange.length
        XCTAssertEqual(nsText.substring(with: NSRange(location: afterHidden, length: 1)), "\n")
        XCTAssertEqual(nsText.substring(from: afterHidden + 1), "}")
    }

    func testUnbalancedInputDoesNotCrash() {
        // Kullanıcı yazarken metin yarım kalır; katlama bozulmamalı.
        XCTAssertTrue(JSONFolding.regions(in: "{ \"a\": [1, 2").isEmpty)
        XCTAssertTrue(JSONFolding.regions(in: "} ]").isEmpty)
    }

    func testRegionLookupByLine() {
        let json = text("{", "  \"list\": [", "    1", "  ]", "}")
        let regions = JSONFolding.regions(in: json)
        XCTAssertEqual(JSONFolding.region(startingAt: 1, in: regions)?.kind, .array)
        XCTAssertNil(JSONFolding.region(startingAt: 2, in: regions))
    }

    func testOutermostSkipsNestedRegions() {
        let json = text("{", "  \"list\": [", "    1", "  ]", "}")
        let outermost = JSONFolding.outermost(JSONFolding.regions(in: json))
        XCTAssertEqual(outermost.count, 1)
        XCTAssertEqual(outermost.first?.kind, .object)
    }

    func testSiblingRegionsAreBothOutermost() {
        let json = text("{", "  \"a\": {", "    \"x\": 1", "  },", "  \"b\": {", "    \"y\": 2", "  }", "}")
        let regions = JSONFolding.regions(in: json)
        XCTAssertEqual(regions.count, 3)
        XCTAssertEqual(JSONFolding.outermost(regions).count, 1, "dış nesne hepsini kapsıyor")
    }

    func testArrayOfObjects() {
        let json = text("[", "  {", "    \"a\": 1", "  },", "  {", "    \"b\": 2", "  }", "]")
        let regions = JSONFolding.regions(in: json)
        XCTAssertEqual(regions.map(\.kind), [.array, .object, .object])
    }
}
