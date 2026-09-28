import AppKit

/// Katlanan aralıkları çizimden düşüren layout delegesi.
///
/// Ayrı sınıf olmasının sebebi test: NSTextView'sız, yalnızca
/// NSTextStorage + NSLayoutManager + NSTextContainer ile kurulup "hangi
/// karakterler hangi satıra düştü" diye sorulabiliyor. Katlamanın kapanış
/// parantezini yutup yutmadığı ancak böyle kesin ölçülür.
final class FoldingLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    /// Gizlenecek karakter aralıkları. Değişince çağıran taraf glyph'leri
    /// geçersiz kılmalı (`invalidateGlyphs`).
    var hiddenRanges: [NSRange] = []

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }
        var updated = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var changed = false
        for index in 0..<glyphRange.length {
            let character = characterIndexes[index]
            guard hiddenRanges.contains(where: { NSLocationInRange(character, $0) }) else { continue }
            updated[index] = .null
            changed = true
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(
            glyphs,
            properties: &updated,
            characterIndexes: characterIndexes,
            font: font,
            forGlyphRange: glyphRange
        )
        return glyphRange.length
    }
}
