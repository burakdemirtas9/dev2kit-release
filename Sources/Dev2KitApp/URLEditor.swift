import AppKit
import SwiftUI
import Dev2KitCore

/// Adres alanı (kullanıcı isteği, 2026-10-20): odak dışında tek satır ve
/// yatay kaydırılabilir; odakta sığmıyorsa aynı genişlikte aşağı doğru
/// sarılarak büyür (en çok `maxHeight`, sonra içinde dikey kaydırma).
///
/// Neden `NSTextView`: `TextField` tek satırda kalıyor, üstüne çizilen
/// `{{değişken}}` vurgusu da metinle birlikte sarılamıyor ve kaymıyordu.
/// Eski vurgu katmanı `fixedSize` olduğu için alanın dışına taşıp Gönder
/// düğmesinin üstüne biniyordu. Burada renk metnin özniteliği: sarılınca ve
/// kayınca metinle birlikte gider. Sarma yalnızca görsel; değere satır sonu
/// ya da boşluk eklenmez, Enter göndermeye devam eder.
struct URLEditor: NSViewRepresentable {
    @Binding var text: String
    /// Odakta mı (sarılı görünüm). Değeri AppKit bildirir (`onEditingChange`);
    /// SwiftUI yüksekliği buna göre sorar.
    let isEditing: Bool
    let limit: Int
    /// Tanımlı değişken adları (mor; diğerleri kırmızı). Kapanış (closure)
    /// değil küme: SwiftUI gövdede hesaplayınca environment değişince alan
    /// yeniden boyanır. Eskiden değer kaydedilse de kırmızı kalıyordu.
    let definedVariables: Set<String>
    let onSubmit: () -> Void
    let onEditingChange: (Bool) -> Void
    let onLimitRejected: () -> Void
    /// Değişkene tıklandı (sürüklemeden) ya da imleç değişkendeyken ⌥⏎:
    /// ad, tıklanan parçanın dikdörtgeni (metin görünümü koordinatında) ve
    /// metin görünümü. Baloncuk buna bağlanır.
    let onVariableClick: (String, NSRect, NSView) -> Void
    /// Arttıkça alan odak alır ve imleç sona gider (öneri tamamlanınca).
    var focusRequest = 0

    /// Tek satır yüksekliği: kapsülle aynı.
    static let lineHeight: CGFloat = 28
    /// Sarılı görünümün en fazla yüksekliği (~7 satır); sonra dikey kaydırma.
    static let maxHeight: CGFloat = 128
    static let verticalInset: CGFloat = 6
    static var font: NSFont { .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        let textView = AddressTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: Self.lineHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Adres")
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.applyMode(editing: false)
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            // Dışarıdan değişti (ör. query sekmesi): seçim sığdığı kadar korunur.
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        coordinator.applyMode(editing: isEditing)
        coordinator.highlight()
        if coordinator.handledFocusRequest != focusRequest {
            coordinator.handledFocusRequest = focusRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }
    }

    /// Genişlik her zaman önerilen genişlik: içerik ne kadar uzun olursa
    /// olsun alan komşu düğmeleri itmez (taşmanın asıl sebebi buydu).
    /// Yükseklik odakta içeriğe göre, odak dışında tek satır.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        guard isEditing else { return CGSize(width: width, height: Self.lineHeight) }
        return CGSize(width: width, height: Self.height(for: text, width: width))
    }

    /// Sarılı metnin yüksekliği, `lineHeight` ile `maxHeight` arasında.
    static func height(for text: String, width: CGFloat) -> CGFloat {
        guard width > 1, !text.isEmpty else { return lineHeight }
        let measured = NSAttributedString(string: text, attributes: Coordinator.baseAttributes).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = ceil(measured.height) + 2 * verticalInset
        return min(max(height, lineHeight), maxHeight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: URLEditor
        weak var textView: AddressTextView?
        weak var scrollView: NSScrollView?
        var handledFocusRequest = 0
        private var isWrapped: Bool?

        init(_ parent: URLEditor) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
        }

        /// Harf bazında sarma: adresin içinde boşluk yok, kelime sınırı beklenmez.
        static var baseAttributes: [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byCharWrapping
            return [.font: URLEditor.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        }

        // MARK: Görünüm kipi

        /// Tek satır (yatay kaydırma) ↔ sarılı (genişliğe sabit, dikey kaydırma).
        func applyMode(editing: Bool) {
            guard let textView, let scrollView, let container = textView.textContainer else { return }
            let wrapped = editing
            guard isWrapped != wrapped else {
                if wrapped { textView.scrollRangeToVisible(textView.selectedRange()) }
                return
            }
            isWrapped = wrapped
            if wrapped {
                scrollView.hasHorizontalScroller = false
                scrollView.hasVerticalScroller = true
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                container.widthTracksTextView = true
                container.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
                textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
                textView.scrollRangeToVisible(textView.selectedRange())
            } else {
                // Kaydırma çubuğu yok: 28 pt'lik satırda metnin üstüne biniyordu.
                // İzleme yüzeyiyle yatay kaydırma çubuksuz da çalışır.
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
                textView.autoresizingMask = []
                textView.isHorizontallyResizable = true
                container.widthTracksTextView = false
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textView.sizeToFit()
                // Odak gidince adresin başı görünsün.
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        // MARK: Renk

        /// `{{değişken}}` aralıkları renkli; geri kalan düz metin. Değer
        /// değişmez, yalnızca öznitelik.
        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(Self.baseAttributes, range: full)
            for variable in TemplateVariables.variableRanges(in: textView.string) {
                let defined = parent.definedVariables.contains(variable.name)
                storage.addAttributes([
                    .foregroundColor: defined ? Theme.variableNS : Theme.undefinedVariableNS,
                    .backgroundColor: defined ? Theme.variableBackgroundNS : Theme.undefinedVariableBackgroundNS,
                ], range: variable.range)
            }
            storage.endEditing()
            textView.typingAttributes = Self.baseAttributes
        }

        // MARK: Odak

        func editingChanged(_ editing: Bool) {
            parent.onEditingChange(editing)
        }

        // MARK: Değişkene tıklama

        /// Noktadaki değişken ve tıklanan karakter (yoksa `nil`). Değişken
        /// birden çok görsel satıra bölünse de her parçası aynı aralıkta.
        func variable(at point: NSPoint) -> (name: String, range: NSRange, index: Int)? {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
            let origin = textView.textContainerOrigin
            let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
            var fraction: CGFloat = 0
            let index = layoutManager.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
            guard index < (textView.string as NSString).length else { return nil }
            // Satır sonundaki boşluğa tıklama en yakın karakteri verir; yalnızca
            // karakterin kendi kutusu sayılır.
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            guard layoutManager.boundingRect(forGlyphRange: glyphs, in: container).contains(local) else { return nil }
            return variable(containing: index)
        }

        func variable(containing index: Int) -> (name: String, range: NSRange, index: Int)? {
            guard let textView else { return nil }
            for variable in TemplateVariables.variableRanges(in: textView.string) where NSLocationInRange(index, variable.range) {
                return (variable.name, variable.range, index)
            }
            return nil
        }

        /// Baloncuğu, düzen oturduktan sonra (tıklama alanı genişletmiş
        /// olabilir) tıklanan karakterin bulunduğu satır parçasına bağlar.
        func present(_ hit: (name: String, range: NSRange, index: Int)) {
            DispatchQueue.main.async { [weak self] in
                DispatchQueue.main.async {
                    guard let self, let textView = self.textView,
                          let layoutManager = textView.layoutManager, let container = textView.textContainer,
                          NSMaxRange(hit.range) <= (textView.string as NSString).length else { return }
                    layoutManager.ensureLayout(for: container)
                    textView.scrollRangeToVisible(NSRange(location: hit.index, length: 0))
                    // Değişkenin, tıklanan karakterle aynı görsel satırdaki parçası.
                    let glyph = layoutManager.glyphIndexForCharacter(at: hit.index)
                    var lineGlyphs = NSRange()
                    layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
                    let variableGlyphs = layoutManager.glyphRange(forCharacterRange: hit.range, actualCharacterRange: nil)
                    let piece = NSIntersectionRange(variableGlyphs, lineGlyphs)
                    var rect = layoutManager.boundingRect(forGlyphRange: piece.length > 0 ? piece : NSRange(location: glyph, length: 1), in: container)
                    let origin = textView.textContainerOrigin
                    rect.origin.x += origin.x
                    rect.origin.y += origin.y
                    self.parent.onVariableClick(hit.name, rect, textView)
                }
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
        }

        /// Satır sonu girmez (yapıştırmada da ayıklanır); sınır aşan değişiklik
        /// alana girmeden reddedilir.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }
            let clean = replacement.components(separatedBy: .newlines).joined()
            let resulting = (textView.string as NSString).length - range.length + (clean as NSString).length
            if resulting > parent.limit {
                DispatchQueue.main.async { [parent] in parent.onLimitRejected() }
                return false
            }
            if clean != replacement {
                textView.insertText(clean, replacementRange: range)
                return false
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⌥⏎: imleç bir değişkendeyse baloncuğu açar (klavye yolu);
                // değilse ⏎ gibi gönderir.
                if let hit = variable(containing: textView.selectedRange().location) ?? variable(containing: max(0, textView.selectedRange().location - 1)),
                   textView.selectedRange().length == 0 {
                    present(hit)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Esc: düzenlemeyi bitir, tek satıra dön.
                textView.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// Adres metin görünümü: odak değişimini bildirir; değişkene tıklamayı
/// baloncuğa çevirir.
final class AddressTextView: NSTextView {
    weak var coordinator: URLEditor.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { coordinator?.editingChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.editingChanged(false) }
        return resigned
    }

    /// Değişken tıklaması tıklama BİTİNCE değerlendirilir: AppKit tıklanan
    /// görünümü `mouseDown`'dan önce ilk yanıtlayıcı yapıyor, "odakta değilse"
    /// koşulu bu yüzden hiç tutmuyordu (regresyonun sebebi). Önce olağan
    /// tıklama (imleç, sürükleyerek seçim) çalışır; tek tıklama ve seçim
    /// boşsa (sürükleme yoksa) baloncuk açılır. Hit-test, tıklama anındaki
    /// düzene göre yapılır (alan sonra genişleyebilir).
    override func mouseDown(with event: NSEvent) {
        let hit = coordinator?.variable(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        guard let hit, event.clickCount == 1, selectedRange().length == 0 else { return }
        coordinator?.present(hit)
    }
}
