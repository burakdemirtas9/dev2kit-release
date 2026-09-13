import AppKit
import SwiftUI

enum CodeLanguage: Equatable {
    case plain
    case json
    case markup      // XML / HTML
    case javascript
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

    /// Bu eşiğin üstünde sözdizimi kuralları çalıştırılmaz: tüm metinde regex
    /// taraması her tuş vuruşunda yapıldığı için büyük gövdelerde yazmayı
    /// kilitliyordu. Metin yine okunur, sadece renklendirilmez.
    static let highlightLimit = 100_000

    static func highlight(_ storage: NSTextStorage, language: CodeLanguage, font: NSFont) {
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: Theme.editorText], range: fullRange)
        guard storage.length <= highlightLimit else {
            storage.endEditing()
            return
        }
        for rule in rules(for: language) {
            rule.regex.enumerateMatches(in: storage.string, range: fullRange) { match, _, _ in
                guard let match, match.range(at: rule.group).location != NSNotFound else { return }
                storage.addAttribute(.foregroundColor, value: rule.color, range: match.range(at: rule.group))
            }
        }
        storage.endEditing()
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
        context.coordinator.highlight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        if textView.string != text {
            // Programatik değişim (ör. Beautify): metni değiştir, yeniden boya.
            textView.string = text
            context.coordinator.highlight(textView)
        } else if context.coordinator.lastLanguage != language {
            context.coordinator.highlight(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var lastLanguage: CodeLanguage?
        private var highlightWorkItem: DispatchWorkItem?

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        deinit {
            highlightWorkItem?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // Hızlı yazarken her tuşta tüm metni yeniden boyamak yerine
            // yazım durduğunda bir kez boya (imleç ve kaydırma da korunur).
            highlightWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlight(textView)
            }
            highlightWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func highlight(_ textView: NSTextView) {
            lastLanguage = parent.language
            guard let storage = textView.textStorage else { return }
            SyntaxHighlighter.highlight(storage, language: parent.language, font: CodeEditor.font)
        }
    }
}
