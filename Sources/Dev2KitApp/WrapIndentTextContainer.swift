import AppKit

/// Sarılan satırın devamını satırın kendi girintisinden başlatır (asılı girinti).
///
/// Kullanıcı bildirimi (2026-10-22): uzun değer (ör. token) sarılınca devam
/// satırları en soldan başlıyor, JSON'un yapısından düşmüş gibi görünüyordu.
/// Devam satırı artık "satırın baştaki boşlukları + `extraIndent` karakter"
/// kadar içeriden başlar.
///
/// Neden metin özniteliği (paragraf `headIndent`) değil: tüm belgeye öznitelik
/// yazmak büyük metinde pahalı; renklendirme yalnızca görünen aralıkta
/// yapıldığı için kaydırdıkça sarma değişirdi. Burada yalnızca dizgicinin her
/// satır için istediği dikdörtgen içeriden verilir: metin, kopyalama ve arama
/// değişmez.
///
/// Performans: satır başını bulmak geriye taramak demek; tek satırlık 5 MB
/// metinde her sarma satırı için baştan taramak karesel olurdu. Son bulunan
/// satır önbellekte; dizgici sırayla ilerlediği için çoğu çağrı önbellekten.
/// Metin her düzenlendiğinde önbellek düşer.
final class WrapIndentTextContainer: NSTextContainer {
    /// Satırın girintisine eklenen karakter sayısı.
    var extraIndent = 2
    /// Girinti dikdörtgenin en fazla bu oranını alır (çok derin girintide
    /// metin tek sütuna sıkışmasın).
    static let maxIndentFraction: CGFloat = 0.6

    private var cachedParagraph: (start: Int, end: Int, indent: CGFloat)?
    private var editObserver: NSObjectProtocol?

    override init(size: NSSize) {
        super.init(size: size)
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, note.object as AnyObject? === self.layoutManager?.textStorage else { return }
            self.cachedParagraph = nil
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    deinit {
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
    }

    override var isSimpleRectangularTextContainer: Bool { false }

    override func lineFragmentRect(
        forProposedRect proposedRect: NSRect,
        at characterIndex: Int,
        writingDirection baseWritingDirection: NSWritingDirection,
        remaining remainingRect: UnsafeMutablePointer<NSRect>?
    ) -> NSRect {
        var rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                          writingDirection: baseWritingDirection, remaining: remainingRect)
        guard let storage = layoutManager?.textStorage, characterIndex < storage.length,
              let paragraph = paragraph(containing: characterIndex, in: storage),
              characterIndex > paragraph.start, paragraph.indent > 0 else { return rect }
        let indent = min(paragraph.indent, rect.width * Self.maxIndentFraction)
        rect.origin.x += indent
        rect.size.width -= indent
        return rect
    }

    /// Karakterin bulunduğu satır ve devam satırlarının girintisi.
    private func paragraph(containing index: Int, in storage: NSTextStorage) -> (start: Int, end: Int, indent: CGFloat)? {
        if let cached = cachedParagraph, index >= cached.start, index < cached.end { return cached }
        let string = storage.string as NSString
        let length = string.length
        var start = index
        while start > 0, !Self.isLineBreak(string.character(at: start - 1)) { start -= 1 }
        var end = index
        while end < length, !Self.isLineBreak(string.character(at: end)) { end += 1 }
        var columns = 0
        var cursor = start
        while cursor < end {
            let unit = string.character(at: cursor)
            if unit == 0x20 { columns += 1 } else if unit == 0x09 { columns += 4 } else { break }
            cursor += 1
        }
        let font = (storage.attribute(.font, at: start, effectiveRange: nil) as? NSFont)
            ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let result = (start: start, end: end + 1, indent: CGFloat(columns + extraIndent) * spaceWidth)
        cachedParagraph = result
        return result
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        FoldingLayoutDelegate.isLineBreak(unit)
    }
}
