import AppKit
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Katlamanın gerçekten NE çizdiğini ölçer.
///
/// Neden bu test: katlama "gizlendi mi" ile bitmiyor — kapanış parantezi
/// görünür kalmalı, yoksa kullanıcı bloğun nerede bittiğini göremez.
/// Ekran görüntüsüne bakarak bunu doğrulamak güvenilmez; burada metin
/// yerleşimi doğrudan sorgulanıyor.
@MainActor
final class FoldingLayoutTests: XCTestCase {
    private let json = """
    {
      "args": {},
      "headers": {
        "Accept": "*/*",
        "Host": "httpbin.org"
      },
      "url": "https://httpbin.org/get"
    }
    """

    /// Verilen aralıklar katlıyken ekranda oluşan satırların içeriği.
    private func renderedLines(hiding ranges: [NSRange], in text: String) -> [String] {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 2_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                             range: NSRange(location: 0, length: storage.length))

        let delegate = FoldingLayoutDelegate()
        delegate.hiddenRanges = ranges
        layoutManager.delegate = delegate
        layoutManager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length),
                                       changeInLength: 0, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: container)

        let nsText = text as NSString
        var lines: [String] = []
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, _, _, glyphRange, _ in
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var visible = ""
            for offset in 0..<characters.length {
                let index = characters.location + offset
                guard !ranges.contains(where: { NSLocationInRange(index, $0) }) else { continue }
                visible += nsText.substring(with: NSRange(location: index, length: 1))
            }
            lines.append(visible.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines
    }

    func testWithoutFoldingEveryLineIsRendered() {
        let lines = renderedLines(hiding: [], in: json)
        XCTAssertEqual(lines.count, 8, "katlama yokken tüm satırlar durmalı: \(lines)")
    }

    func testFoldingInnerObjectHidesItsLinesOnly() throws {
        let regions = JSONFolding.regions(in: json)
        let headers = try XCTUnwrap(regions.first { $0.openLine == 2 })
        let lines = renderedLines(hiding: [headers.hiddenRange], in: json)
        // 3 satır gizlendiği için toplam satır sayısı düşmeli.
        XCTAssertLessThan(lines.count, 8)
        XCTAssertFalse(lines.contains { $0.contains("Accept") }, "gizlenen içerik çizilmemeli: \(lines)")
        XCTAssertTrue(lines.contains { $0.contains("url") }, "katlama sonrası içerik durmalı: \(lines)")
    }

    func testClosingBraceStaysVisibleAfterFolding() throws {
        // Asıl soru: blok nerede bitiyor, kullanıcı görebiliyor mu?
        let regions = JSONFolding.regions(in: json)
        let headers = try XCTUnwrap(regions.first { $0.openLine == 2 })
        let lines = renderedLines(hiding: [headers.hiddenRange], in: json)
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("}"), "kapanış parantezi görünür kalmalı: \(lines)")
    }

    /// Kapanış parantezinin yerleşimdeki hali: gizlenmiş mi, nereye kondu?
    ///
    /// `usedRect` genişliği bu soruyu yanıtlamıyor — katlanmış satırda
    /// yerleşim genişliği son karakteri saymıyor (ölçüldü). Doğru ölçüt
    /// glyph'in kendi özelliği ve konumu.
    private func closingBraceLayout(hiding ranges: [NSRange], in text: String)
        -> (property: NSLayoutManager.GlyphProperty, x: CGFloat)? {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 2_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                             range: NSRange(location: 0, length: storage.length))
        let delegate = FoldingLayoutDelegate()
        delegate.hiddenRanges = ranges
        layoutManager.delegate = delegate
        layoutManager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length),
                                       changeInLength: 0, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: container)

        let closingIndex = (text as NSString).range(of: "}", options: .backwards).location
        for glyph in 0..<layoutManager.numberOfGlyphs
        where layoutManager.characterIndexForGlyph(at: glyph) == closingIndex {
            return (layoutManager.propertyForGlyph(at: glyph), layoutManager.location(forGlyphAt: glyph).x)
        }
        return nil
    }

    func testClosingBraceStaysOnItsOwnLine() throws {
        // Kök katlanınca iki satır kalır: açılış ve kapanış. Blok nerede
        // başlıyor nerede bitiyor, ikisi de görünür.
        let regions = JSONFolding.regions(in: json)
        let root = try XCTUnwrap(regions.first { $0.openLine == 0 })
        let lines = renderedLines(hiding: [root.hiddenRange], in: json)
        XCTAssertEqual(lines.count, 2, "açılış ve kapanış satırı kalmalı: \(lines)")
        XCTAssertEqual(lines.first, "{")
        XCTAssertEqual(lines.last, "}")
    }

    func testFoldedContentIsNotRendered() throws {
        let regions = JSONFolding.regions(in: json)
        let root = try XCTUnwrap(regions.first { $0.openLine == 0 })
        let joined = renderedLines(hiding: [root.hiddenRange], in: json).joined()
        XCTAssertFalse(joined.contains("args"), "katlanan içerik çizilmemeli: \(joined)")
        XCTAssertFalse(joined.contains("httpbin"), "katlanan içerik çizilmemeli: \(joined)")
    }
}
