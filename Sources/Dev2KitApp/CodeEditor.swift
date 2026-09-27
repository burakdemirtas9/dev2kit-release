import AppKit
import SwiftUI
import Dev2KitCore

enum CodeLanguage: Equatable {
    case plain
    case json
    case markup      // XML / HTML
    case javascript

    /// Core'daki tür tahmininin arayüz karşılığı. XML ve HTML aynı
    /// renklendirme kurallarını kullandığı için ikisi de `markup`.
    init(_ kind: Beautifier.Kind) {
        switch kind {
        case .json: self = .json
        case .xml, .html: self = .markup
        case .javascript: self = .javascript
        case .plain: self = .plain
        }
    }
}

/// Regex tabanlı, hafif sözdizimi renklendirici.
/// Kurallar sırayla uygulanır; sonraki kural öncekinin rengini ezer
/// (ör. JSON'da önce tüm string'ler, sonra `:` öncesindeki key'ler boyanır).
enum SyntaxHighlighter {
    private struct Rule {
        let regex: NSRegularExpression
        let color: NSColor
        let group: Int

        init(_ pattern: String, _ color: NSColor, group: Int = 0) {
            // Kalıplar sabit ve derleme anında bilindiği için force try güvenli.
            self.regex = try! NSRegularExpression(pattern: pattern)
            self.color = color
            self.group = group
        }
    }

    private static let jsonRules: [Rule] = [
        Rule(#"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#, Theme.syntaxNumber),
        Rule(#"\b(?:true|false|null)\b"#, Theme.syntaxKeyword),
        Rule(#""(?:\\.|[^"\\])*""#, Theme.syntaxString),
        Rule(#"("(?:\\.|[^"\\])*")\s*:"#, Theme.syntaxKey, group: 1),
    ]

    private static let markupRules: [Rule] = [
        Rule(#"</?\s*([A-Za-z][\w:.-]*)"#, Theme.syntaxKey, group: 1),
        Rule(#"\b([\w:.-]+)\s*="#, Theme.syntaxAttribute, group: 1),
        Rule(#""[^"]*"|'[^']*'"#, Theme.syntaxString),
        Rule(#"<!--[\s\S]*?-->"#, Theme.syntaxComment),
    ]

    private static let javascriptRules: [Rule] = [
        Rule(#"-?\b\d+(?:\.\d+)?\b"#, Theme.syntaxNumber),
        Rule(#"\b(?:const|let|var|function|return|if|else|for|while|switch|case|break|class|new|this|typeof|true|false|null|undefined|async|await|import|export|from|try|catch|finally|throw)\b"#, Theme.syntaxKeyword),
        Rule(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#, Theme.syntaxString),
        Rule(#"//[^\n]*|/\*[\s\S]*?\*/"#, Theme.syntaxComment),
    ]

    private static func rules(for language: CodeLanguage) -> [Rule] {
        switch language {
        case .plain: return []
        case .json: return jsonRules
        case .markup: return markupRules
        case .javascript: return javascriptRules
        }
    }

    /// Renklendirme YALNIZCA görünen bölgede yapılır.
    ///
    /// Ölçüm (release): 55.000 karakterlik bir JSON'u baştan sona boyamak
    /// 11,6 ms sürüyordu ve bu iş her sekme değişiminde iki kez (gövde +
    /// yanıt) ana thread'de koşuyordu — sekme geçişindeki takılma buydu.
    /// Ekranda 40-50 satır varken tüm belgeyi boyamanın karşılığı yok;
    /// maliyet artık belge boyutundan bağımsız.
    ///
    /// Yan etki: bölge sınırını aşan yapılar (çok satırlı yorum gibi) kırpılmış
    /// görünebilir. Bölge satır başlarına genişletilerek etkisi küçültülüyor.
    static let margin = 2_000

    /// Yazı tipi ve temel renk tüm belgeye bir kez uygulanır; metin değişince
    /// çağrılır. Renklendirmenin kendisi ayrı (bkz. `colorize`).
    static func applyBaseAttributes(_ storage: NSTextStorage, font: NSFont) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: Theme.editorText], range: full)
        storage.endEditing()
    }

    /// Verilen aralığı (satır sınırlarına genişleterek) renklendirir.
    static func colorize(_ storage: NSTextStorage, language: CodeLanguage, range: NSRange) {
        let rules = rules(for: language)
        guard !rules.isEmpty, storage.length > 0 else { return }
        let target = expand(range, in: storage.string)
        storage.beginEditing()
        storage.setAttributes([.foregroundColor: Theme.editorText], range: target)
        for rule in rules {
            rule.regex.enumerateMatches(in: storage.string, range: target) { match, _, _ in
                guard let match, match.range(at: rule.group).location != NSNotFound else { return }
                storage.addAttribute(.foregroundColor, value: rule.color, range: match.range(at: rule.group))
            }
        }
        storage.endEditing()
    }

    /// Görünen aralığı iki yana `margin` kadar açar ve satır sınırlarına oturtur:
    /// kaydırırken kenarda yarım boyanmış satır görünmesin.
    private static func expand(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let start = max(0, range.location - margin)
        let end = min(length, range.location + range.length + margin)
        guard start < end else { return NSRange(location: 0, length: 0) }
        return (text as NSString).lineRange(for: NSRange(location: start, length: end - start))
    }
}

/// Sözdizimi renklendirmeli, düz metin kod editörü.
/// SwiftUI TextEditor renklendirme desteklemediği için NSTextView sarılır.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    var isEditable: Bool = true

    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.string = text
        context.coordinator.textChanged(textView)
        // Kaydırdıkça yeni görünen bölge boyanır.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        if textView.string != text {
            // Programatik değişim (ör. Beautify): metni değiştir, yeniden boya.
            textView.string = text
            context.coordinator.textChanged(textView)
        } else if context.coordinator.lastLanguage != language {
            context.coordinator.textChanged(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var lastLanguage: CodeLanguage?
        private var scrollObserver: NSObjectProtocol?

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // ANINDA boyanır, gecikme yok. Eskiden 120 ms ertelenirdi: tüm belge
            // taranacağı için her tuşta yapılamazdı. Yapıştırılan JSON önce
            // renksiz görünüp sonra renklenmesinin sebebi buydu. Artık iş
            // yalnızca görünen bölge kadar (~1,5 ms), ertelemeye gerek yok.
            colorizeVisible(textView)
        }

        /// Metin (ya da dil) değişti: temel biçim tüm belgeye, renk görünen bölgeye.
        func textChanged(_ textView: NSTextView) {
            lastLanguage = parent.language
            guard let storage = textView.textStorage else { return }
            SyntaxHighlighter.applyBaseAttributes(storage, font: CodeEditor.font)
            colorizeVisible(textView)
        }

        func colorizeVisible(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            SyntaxHighlighter.colorize(storage, language: parent.language, range: visibleRange(of: textView))
        }

        /// Ekranda duran karakter aralığı. Yerleşim yalnızca bu dikdörtgen için
        /// zorlanır, belgenin tamamı için değil.
        private func visibleRange(of textView: NSTextView) -> NSRange {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else {
                return NSRange(location: 0, length: textView.string.utf16.count)
            }
            let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
            return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        }

        func observeScrolling(of scrollView: NSScrollView, textView: NSTextView) {
            guard scrollObserver == nil else { return }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                MainActor.assumeIsolated { self.colorizeVisible(textView) }
            }
        }
    }
}
