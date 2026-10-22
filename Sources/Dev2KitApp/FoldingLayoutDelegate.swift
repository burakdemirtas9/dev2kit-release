import AppKit

/// Katlanan aralıkları çizimden düşüren layout delegesi.
///
/// Ayrı sınıf olmasının sebebi test: NSTextView'sız, yalnızca
/// NSTextStorage + NSLayoutManager + NSTextContainer ile kurulup "hangi
/// karakterler hangi satıra düştü" diye sorulabiliyor. Katlamanın kapanış
/// parantezini yutup yutmadığı ancak böyle kesin ölçülür.
///
/// Özet (2026-10-19, kullanıcı isteği): her görünür katlı bölgenin İLK gizli
/// karakteri boş değil, özet genişliğinde bir boşluk glyph'i olur
/// ("… 30 keys"); yazıyı `FoldingLayoutManager` o boşluğa çizer.
final class FoldingLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    /// Gizlenecek karakter aralıkları (yalnızca EN DIŞTAKİ katlı bölgeler,
    /// konuma göre sıralı). Değişince çağıran taraf glyph'leri geçersiz
    /// kılmalı (`invalidateGlyphs`).
    var hiddenRanges: [NSRange] = [] {
        didSet { sorted = hiddenRanges.sorted { $0.location < $1.location } }
    }
    /// Gizli aralığın başındaki karakter → özet yazısı.
    var placeholders: [Int: String] = [:]
    /// Özetin yazı tipi (editörden biraz küçük).
    var placeholderFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private var sorted: [NSRange] = []

    /// Özet kapsülünün yazı dışındaki genişliği.
    static let placeholderPadding: CGFloat = 12

    func placeholderWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: placeholderFont]).width + Self.placeholderPadding
    }

    /// İkili arama: "tümünü katla" binlerce bölge katlayabilir; her karakter
    /// için hepsini taramak 4 MB'ta donma demekti.
    func isHidden(_ character: Int) -> Bool {
        var low = 0, high = sorted.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = sorted[mid]
            if character < range.location { high = mid - 1 }
            else if character >= range.location + range.length { low = mid + 1 }
            else { return true }
        }
        return false
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let string = layoutManager.textStorage?.string as NSString?
        var updated = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var changed = false
        for index in 0..<glyphRange.length {
            let character = characterIndexes[index]
            guard isHidden(character) else { continue }
            if placeholders[character] != nil {
                // Özetin yeri: boşluk glyph'i (genişliği aşağıdaki kutudan).
                updated[index] = .controlCharacter
            } else if let string, Self.isLineBreak(string.character(at: character)) {
                // Gizli satır sonu `.null` YAPILMAZ: dizgici onu yine paragraf
                // sonu sayıyor ve satır durumu kayıyordu. Ölçüldü (2026-10-22,
                // kullanıcı ekran görüntüsü): yan yana katlı bloklarda sonraki
                // görünür satır sonu yeni satır açmıyor, gizli glyph'ler
                // ilerleyip rastgele yerde sarıyor; satırlar üst üste
                // biniyordu. Denetim karakteri + sıfır ilerleme (aşağıda).
                updated[index] = .controlCharacter
            } else {
                updated[index] = .null
            }
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

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        if placeholders[charIndex] != nil { return .whitespace }
        // Katlı bölgedeki satır sonu satır kırmaz ve yer kaplamaz.
        return isHidden(charIndex) ? .zeroAdvancement : action
    }

    /// Satır/paragraf sonu: LF, CR, NEL, satır ve paragraf ayırıcı.
    static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x85 || unit == 0x2028 || unit == 0x2029
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let text = placeholders[charIndex] else { return .zero }
        return NSRect(x: glyphPosition.x, y: 0, width: placeholderWidth(text) + 6, height: proposedRect.height)
    }
}

/// Katlı bölge özetini ("… 30 keys") delegenin ayırdığı boşluğa çizer.
final class FoldingLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let folding = delegate as? FoldingLayoutDelegate, !folding.placeholders.isEmpty,
              let container = textContainers.first else { return }
        for (character, text) in folding.placeholders {
            let glyph = glyphIndexForCharacter(at: character)
            guard NSLocationInRange(glyph, glyphsToShow) else { continue }
            var rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            rect.origin.x += origin.x + 4
            rect.origin.y += origin.y
            let size = (text as NSString).size(withAttributes: [.font: folding.placeholderFont])
            let pill = NSRect(x: rect.minX, y: rect.midY - size.height / 2 - 1,
                              width: size.width + FoldingLayoutDelegate.placeholderPadding, height: size.height + 2)
            NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            (text as NSString).draw(
                at: NSPoint(x: pill.minX + FoldingLayoutDelegate.placeholderPadding / 2, y: pill.minY + 1),
                withAttributes: [.font: folding.placeholderFont, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
    }
}
