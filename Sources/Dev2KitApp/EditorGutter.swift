import AppKit
import Dev2KitCore

/// Editörün sol şeridi: satır numaraları ve katlama okları.
///
/// `NSRulerView` seçildi çünkü NSTextView ile kaydırmayı ve yerleşimi AppKit
/// zaten eşitliyor; ayrı bir görünümle elle senkronize etmek kırılgan olurdu.
///
/// Performans kuralı (docs/UI-KURALLARI.md 3 ve 5): çizim YALNIZCA görünen
/// satırlar için yapılır, belge boyutundan bağımsızdır. Satır başlangıçları
/// metin değiştiğinde bir kez hesaplanır, çizimde ikili arama ile bulunur.
final class EditorGutter: NSRulerView {
    /// Katlanabilir bölgenin başladığı satırlar (0'dan başlar).
    var foldableLines: Set<Int> = [] { didSet { needsDisplay = true } }
    /// Şu an katlı olan satırlar.
    var foldedLines: Set<Int> = [] { didSet { needsDisplay = true } }
    /// Oka tıklanınca çağrılır.
    var onToggleFold: ((Int) -> Void)?

    /// Her satırın başladığı karakter indeksi. Metin değişince yenilenir.
    private var lineStarts: [Int] = [0]

    private var textView: NSTextView? { clientView as? NSTextView }

    /// Editörle orantılı (⌘+ / ⌘−); varsayılanda 10 pt.
    var fontSize: Double = 10 {
        didSet {
            guard fontSize != oldValue else { return }
            font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
            updateThickness()
            needsDisplay = true
        }
    }
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private static let arrowWidth: CGFloat = 12

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    /// Metin değiştiğinde satır başlangıçlarını ve genişliği tazeler.
    func refresh(text: String) {
        var starts = [0]
        let characters = Array(text.utf16)
        for (index, unit) in characters.enumerated() where unit == 10 {
            starts.append(index + 1)
        }
        lineStarts = starts
        updateThickness()
        needsDisplay = true
    }

    /// Genişlik satır sayısının basamağına ve yazı boyutuna göre: 4 haneli
    /// belgede ya da büyütülmüş yazıda numara kırpılmasın. Rakam genişliği
    /// yazı boyutunun ~%70'i (10 pt'de 7 px, eski sabit değer).
    private func updateThickness() {
        let digits = max(2, String(lineStarts.count).count)
        ruleThickness = CGFloat(digits) * CGFloat(fontSize) * 0.7 + Self.arrowWidth + 12
    }

    /// Karakter indeksinden satır numarası (0'dan başlar).
    private func line(at characterIndex: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= characterIndex { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Şeridin kendi zemini.
    ///
    /// Varsayılan `NSRulerView` zemini pencere grisiyle aynı; üstündeki
    /// segmentli denetimle yan yana gelince göz ikisini tek bir şerit olarak
    /// okuyor ve satır numarası alanı araç çubuğuna taşmış gibi görünüyordu.
    /// Editörün zeminiyle boyanıp sağına ince bir ayraç konuyor.
    ///
    /// Boyama `drawHashMarksAndLabels` içinde: `draw(_:)`'i ezmek ruler'ın
    /// kendi çizim zincirini bozup editörü tamamen boş bırakıyordu (denendi).
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let inset = textView.textContainerInset.height

        var lastLine = -1
        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphs) { _, usedRect, _, glyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let lineNumber = self.line(at: characterIndex)
            // Sarılmış satırın devamına numara yazılmaz.
            guard lineNumber != lastLine else { return }
            lastLine = lineNumber

            let y = usedRect.minY + inset - visibleRect.minY
            self.drawNumber(lineNumber + 1, at: y, height: usedRect.height)
            if self.foldableLines.contains(lineNumber) {
                self.drawArrow(folded: self.foldedLines.contains(lineNumber), at: y, height: usedRect.height)
            }
        }

        // Son (boş) satır. Metin hiç yokken ya da satır sonuyla bitiyorken
        // TextKit bunun için ayrı bir "ekstra" parça tutuyor ve yukarıdaki
        // döngüye girmiyor. Atlanınca boş gövdede şerit bomboş kalıyor ve
        // ekranda alakasız bir sütun gibi duruyordu.
        if layoutManager.extraLineFragmentTextContainer != nil {
            let extra = layoutManager.extraLineFragmentUsedRect
            let y = extra.minY + inset - visibleRect.minY
            drawNumber(lineStarts.count, at: y, height: max(extra.height, Self.fallbackLineHeight))
        } else if lastLine < 0 {
            // Hiç parça çizilmediyse (boş metin, yerleşim henüz kurulmamış)
            // şerit yine de boş kalmasın: her editörde en az 1. satır vardır.
            drawNumber(1, at: inset - visibleRect.minY, height: Self.fallbackLineHeight)
        }
    }

    /// Yerleşim henüz satır yüksekliği vermediğinde kullanılan ölçü.
    private static let fallbackLineHeight: CGFloat = 15

    private func drawNumber(_ number: Int, at y: CGFloat, height: CGFloat) {
        let text = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let size = text.size(withAttributes: attributes)
        let x = ruleThickness - Self.arrowWidth - size.width - 6
        text.draw(at: NSPoint(x: x, y: y + (height - size.height) / 2), withAttributes: attributes)
    }

    /// Katlama üçgeni. SF Symbol yerine elle çizim: `NSRulerView` çevrik
    /// koordinatta çalışıyor ve simge dikey olarak ters düşüyordu. Üçgen bu
    /// boyutta (8pt) chevron'dan daha okunur ve yönü açıkça kontrol edilebilir.
    private func drawArrow(folded: Bool, at y: CGFloat, height: CGFloat) {
        let size: CGFloat = 7
        let left = ruleThickness - Self.arrowWidth + 1
        let top = y + (height - size) / 2
        let path = NSBezierPath()
        if folded {
            // ▶ kapalı
            path.move(to: NSPoint(x: left, y: top))
            path.line(to: NSPoint(x: left, y: top + size))
            path.line(to: NSPoint(x: left + size, y: top + size / 2))
        } else {
            // ▼ açık
            path.move(to: NSPoint(x: left, y: top + 1))
            path.line(to: NSPoint(x: left + size, y: top + 1))
            path.line(to: NSPoint(x: left + size / 2, y: top + size))
        }
        path.close()
        NSColor.tertiaryLabelColor.setFill()
        path.fill()
    }

    // MARK: - Tıklama

    override func mouseDown(with event: NSEvent) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let point = convert(event.locationInWindow, from: nil)
        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let inset = textView.textContainerInset.height

        var hit: Int?
        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphs) { _, usedRect, _, glyphRange, stop in
            let y = usedRect.minY + inset - visibleRect.minY
            guard point.y >= y, point.y <= y + usedRect.height else { return }
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            hit = self.line(at: characterIndex)
            stop.pointee = true
        }
        guard let line = hit, foldableLines.contains(line) else { return }
        onToggleFold?(line)
    }
}
