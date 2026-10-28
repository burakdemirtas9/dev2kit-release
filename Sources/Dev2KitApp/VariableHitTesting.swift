import AppKit
import Dev2KitCore

/// Metin görünümünde `{{değişken}}`e tıklama: hangi değişken, baloncuk nereye.
/// Adres alanı (`URLEditor`) ve istek gövdesi (`CodeEditor`, yalnızca API
/// Client) ortak kullanır.
enum VariableHitTesting {
    struct Hit: Equatable {
        let name: String
        /// Değişkenin metindeki aralığı (UTF-16).
        let range: NSRange
        /// Tıklanan karakter.
        let index: Int
    }

    /// Noktadaki değişken (metin görünümü koordinatında); yoksa `nil`. Satır
    /// sonundaki boşluğa tıklama en yakın karakteri verir; yalnızca
    /// karakterin kendi kutusu sayılır. Değişken birden çok görsel satıra
    /// bölünse de her parçası aynı aralıkta.
    static func variable(at point: NSPoint, in textView: NSTextView) -> Hit? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        let origin = textView.textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < (textView.string as NSString).length else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard layoutManager.boundingRect(forGlyphRange: glyphs, in: container).contains(local) else { return nil }
        return variable(containing: index, in: textView.string)
    }

    /// Konumu içeren değişken. Yalnızca konumun satırı taranır: gövde
    /// MB'larca olabilir, tıklama başına tüm metin taranmasın.
    static func variable(containing index: Int, in text: String) -> Hit? {
        let string = text as NSString
        guard index >= 0, index < string.length else { return nil }
        let line = string.lineRange(for: NSRange(location: index, length: 0))
        for variable in TemplateVariables.variableRanges(in: string.substring(with: line)) {
            let range = NSRange(location: variable.range.location + line.location, length: variable.range.length)
            if NSLocationInRange(index, range) { return Hit(name: variable.name, range: range, index: index) }
        }
        return nil
    }

    /// İmleçteki değişken (⌥⏎, klavye yolu): imleç değişkenin içinde ya da
    /// hemen sonunda. Seçim varsa `nil`.
    static func variableAtCursor(of textView: NSTextView) -> Hit? {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        return variable(containing: selection.location, in: textView.string)
            ?? variable(containing: selection.location - 1, in: textView.string)
    }

    /// Baloncuğu, düzen oturduktan sonra (tıklama alanı genişletmiş olabilir)
    /// tıklanan karakterin bulunduğu görsel satırdaki parçaya bağlar.
    static func present(_ hit: Hit, in textView: NSTextView, onClick: @escaping (String, NSRect, NSView) -> Void) {
        DispatchQueue.main.async { [weak textView] in
            DispatchQueue.main.async {
                guard let textView, let rect = anchorRect(for: hit, in: textView) else { return }
                onClick(hit.name, rect, textView)
            }
        }
    }

    /// Değişkenin, tıklanan karakterle aynı görsel satırdaki parçası (metin
    /// görünümü koordinatında). Yerleşim yalnızca değişkenin aralığı için
    /// yapılır, tüm belge için değil.
    static func anchorRect(for hit: Hit, in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              NSMaxRange(hit.range) <= (textView.string as NSString).length else { return nil }
        layoutManager.ensureLayout(forCharacterRange: hit.range)
        textView.scrollRangeToVisible(NSRange(location: hit.index, length: 0))
        let glyph = layoutManager.glyphIndexForCharacter(at: hit.index)
        var lineGlyphs = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let variableGlyphs = layoutManager.glyphRange(forCharacterRange: hit.range, actualCharacterRange: nil)
        let piece = NSIntersectionRange(variableGlyphs, lineGlyphs)
        var rect = layoutManager.boundingRect(forGlyphRange: piece.length > 0 ? piece : NSRange(location: glyph, length: 1), in: container)
        let origin = textView.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }
}

extension VariablePopoverPresenter {
    /// Değişken baloncuğu: değer, kaynak, kopyala; tanımsızsa "Environment
    /// değişkeni ekle" (pencere yalnızca o düğmeyle açılır). Alanlar ve gövde
    /// aynı kartı gösterir.
    @MainActor
    func showVariable(_ name: String, appState: AppState, at rect: NSRect, in view: NSView) {
        let presenter = self
        show(
            VariablePreviewCard(
                name: name,
                preview: appState.variablePreview(for: name),
                token: appState.cachedToken(forVariable: name),
                onDefine: VariableDefinition.key(from: name) == nil ? nil : {
                    presenter.close()
                    appState.defineVariable(name)
                }
            ),
            at: rect, in: view
        )
    }
}
