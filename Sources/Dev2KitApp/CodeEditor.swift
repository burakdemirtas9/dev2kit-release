import AppKit
import SwiftUI
import Dev2KitCore

enum CodeLanguage: Hashable {
    case plain
    case json
    case markup      // XML / HTML
    case javascript
    case css
    case sql
    case markdown

    /// Katlanabilir mi ve hangi tarayıcıyla.
    ///
    /// JSON/JS parantezle, XML-HTML etiketle katlanır; düz metinde katlanacak
    /// bir yapı yok. Tarayıcı seçimi burada duruyor ki dil eklendiğinde
    /// derleyici eksik kalan yeri göstersin.
    func foldableRegions(in text: String) -> [FoldRegion] {
        switch self {
        case .json, .javascript, .css: return JSONFolding.regions(in: text)
        case .sql, .markdown: return []
        case .markup: return MarkupFolding.regions(in: text)
        case .plain: return []
        }
    }

    var supportsFolding: Bool {
        ![.plain, .sql, .markdown].contains(self)
    }

    /// Core'daki tür tahmininin arayüz karşılığı. XML ve HTML aynı
    /// renklendirme kurallarını kullandığı için ikisi de `markup`.
    init(_ kind: Beautifier.Kind) {
        switch kind {
        case .json: self = .json
        case .xml, .html: self = .markup
        case .javascript: self = .javascript
        case .css: self = .css
        case .sql: self = .sql
        case .markdown: self = .markdown
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
        // Yorum gönderilmez (`RequestBodyComments`); gri görünsün. Dizgi önce
        // eşleşip geçildiği için "https://…" içindeki `//` yorum sayılmaz.
        Rule(#""(?:\\.|[^"\\])*"|(//[^\n]*|/\*[\s\S]*?\*/)"#, Theme.syntaxComment, group: 1),
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

    /// CSS: özellik adı mor, sayı (birimiyle) sarı, string yeşil, `@` kuralları
    /// ve `!important` kırmızı, yorum gri. Sonraki kural öncekini ezer.
    private static let cssRules: [Rule] = [
        Rule(#"([\w-]+)\s*:"#, Theme.syntaxKey, group: 1),
        Rule(#"-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\b"#, Theme.syntaxNumber),
        Rule(#"#[0-9a-fA-F]{3,8}\b"#, Theme.syntaxNumber),
        Rule(#"@[\w-]+|!important"#, Theme.syntaxKeyword),
        Rule(#""[^"]*"|'[^']*'"#, Theme.syntaxString),
        Rule(#"/\*[\s\S]*?\*/"#, Theme.syntaxComment),
    ]

    /// SQL: anahtar kelime kırmızı (büyük/küçük harf duyarsız), sayı sarı,
    /// string yeşil, tanımlayıcı (`"ad"`, `[ad]`) mor, yorum gri.
    private static let sqlRules: [Rule] = [
        Rule(#"(?i)\b(?:select|from|where|and|or|not|null|is|in|as|on|join|left|right|inner|outer|full|cross|group|by|order|having|limit|offset|insert|into|values|update|set|delete|create|table|alter|drop|distinct|union|all|case|when|then|else|end|between|like|asc|desc|with|returning|exists|true|false)\b"#, Theme.syntaxKeyword),
        Rule(#"-?\b\d+(?:\.\d+)?\b"#, Theme.syntaxNumber),
        Rule(#""[^"]*"|\[[^\]\n]*\]|`[^`]*`"#, Theme.syntaxKey),
        Rule(#"'(?:''|[^'])*'"#, Theme.syntaxString),
        Rule(#"--[^\n]*|/\*[\s\S]*?\*/"#, Theme.syntaxComment),
    ]

    /// Markdown: başlık mor, kod (satır içi ve blok çizgileri) yeşil, liste
    /// işareti ve bağlantı adresi sarı.
    private static let markdownRules: [Rule] = [
        Rule(#"(?m)^\s*(?:[-*+]|\d+\.)\s"#, Theme.syntaxNumber),
        Rule(#"\]\([^)\s]*\)"#, Theme.syntaxNumber),
        Rule(#"(?m)^#{1,6}\s.*$"#, Theme.syntaxKey),
        Rule(#"(?m)`[^`\n]+`|^\s*(?:```|~~~).*$"#, Theme.syntaxString),
    ]

    private static func rules(for language: CodeLanguage) -> [Rule] {
        switch language {
        case .plain: return []
        case .json: return jsonRules
        case .markup: return markupRules
        case .javascript: return javascriptRules
        case .css: return cssRules
        case .sql: return sqlRules
        case .markdown: return markdownRules
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
        // `addAttribute`, `setAttributes` DEĞİL: setAttributes yazı tipi dahil
        // tüm öznitelikleri siliyordu; görünen bölge AppKit varsayılanıyla
        // (Helvetica 12, monospace değil) çiziliyor, ⌘+ / ⌘− etkisiz kalıyordu
        // (2026-10-18, ölçülerek bulundu).
        storage.addAttribute(.foregroundColor, value: Theme.editorText, range: target)
        for rule in rules {
            rule.regex.enumerateMatches(in: storage.string, range: target) { match, _, _ in
                guard let match, match.range(at: rule.group).location != NSNotFound else { return }
                storage.addAttribute(.foregroundColor, value: rule.color, range: match.range(at: rule.group))
            }
        }
        storage.endEditing()
    }

    /// Satıra oturtma bu kadar fazla karakter eklerse yapılmaz.
    static let maxLineSnap = 16_384

    /// Görünen aralığı iki yana `margin` kadar açar ve satır sınırlarına oturtur:
    /// kaydırırken kenarda yarım boyanmış satır görünmesin.
    ///
    /// Satır çok uzunsa (sıkıştırılmış JSON tek satırdır) oturtulmaz: "tam
    /// satır" tüm belge demekti, her tuşta ve kaydırmada BÜTÜN metin yeniden
    /// boyanıyordu ve süre öznitelik sayısıyla kareyle büyüyordu (2026-10-18,
    /// ölçüldü: 512 KB tek satırda ~3 sn donma). Kenardaki yarım sözcük yanlış
    /// renkte kalabilir; orası `margin` kadar ekranın dışında.
    static func expand(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let start = max(0, range.location - margin)
        let end = min(length, range.location + range.length + margin)
        guard start < end else { return NSRange(location: 0, length: 0) }
        let window = NSRange(location: start, length: end - start)
        let lines = (text as NSString).lineRange(for: window)
        return lines.length - window.length <= maxLineSnap ? lines : window
    }
}

/// Editörün katlama durumunu SwiftUI tarafından yönetmek için köprü.
///
/// Neden ayrı nesne: "tümünü kapat" düğmesi editörün DIŞINDA (araç çubuğunda)
/// duruyor. Binding ile komut göndermek yerine, editör kendini buraya kaydeder
/// ve düğme doğrudan çağırır — komutun "tüketilmesi" gibi bir durum kalmaz.
@MainActor
final class CodeFoldingController: ObservableObject {
    /// Katlanabilir bölge var mı — düğmeler yoksa hiç gösterilmez.
    @Published fileprivate(set) var isAvailable = false
    @Published fileprivate(set) var hasFolded = false
    /// Satır numarası şeridinin genişliği. Editörün üstüne yerleştirilen
    /// şeyler (ör. boş gövdedeki örnek metin) şeridin altında kalmasın diye
    /// arayüze bildiriliyor; genişlik satır sayısının basamağına göre değişir.
    @Published fileprivate(set) var gutterWidth: CGFloat = 0

    fileprivate var collapse: (() -> Void)?
    fileprivate var expand: (() -> Void)?

    func collapseAll() { collapse?() }
    func expandAll() { expand?() }
}

/// Editöre girişin sınırları (`WorkbenchLimits`). Kullanıcının yaptığı
/// değişiklik (yazma, yapıştırma, sürükleme) metne girmeden ÖNCE denetlenir:
/// donduracak metin editöre hiç girmez. Programla verilen metin denetlenmez;
/// onu veren taraf (durum nesnesi) kendisi karar verir.
struct EditorLimits {
    var maxBytes: Int = WorkbenchLimits.maxInputBytes
    var maxLines: Int = WorkbenchLimits.maxInputLines
    var maxLineBytes: Int = WorkbenchLimits.maxEditorLineBytes
    /// Programla verilen metnin editöre yazılacağı en büyük boyut (çıktı
    /// editörü girdi sınırından büyük metni de GÖSTERİR, bkz. `maxOutputBytes`).
    var maxDisplayBytes: Int = WorkbenchLimits.maxInputBytes
    /// Sonuç `maxBytes`'ı ya da `maxLines`'ı aşıyor: değişiklik yapılmadı.
    /// Mesaj seçili dilde (`Rejection.localized`).
    var onRejected: (WorkbenchLimits.Rejection) -> Void
    /// Sonuçta `maxLineBytes`'tan uzun satır var: değişiklik editöre girmedi,
    /// tam sonuç metni verilir (ör. editörde göstermeden saklamak için).
    var onLongLine: (String) -> Void
}

/// Sözdizimi renklendirmeli, düz metin kod editörü.
/// SwiftUI TextEditor renklendirme desteklemediği için NSTextView sarılır.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    var isEditable: Bool = true
    /// Verilirse satır numaraları ve katlama okları görünür.
    var folding: CodeFoldingController?
    /// Verilirse arama çubuğu bu editörü arayabilir.
    var search: EditorSearchController?
    /// Verilirse bu karakter konumunun (UTF-16) bulunduğu satır hata olarak
    /// kırmızı alt çizgiyle işaretlenir ve görünür alana kaydırılır.
    /// Geçici öznitelik: metne ve renklendirmeye dokunmaz; arama vurgusuyla
    /// (arka plan/ön plan) çakışmasın diye alt çizgi kullanılır.
    var errorOffset: Int?
    /// Kullanıcı editöre tıklayınca/seçim değişince çağrılır. Workbench ⌘F'nin
    /// hangi bölmede (girdi/çıktı) arama açacağını buradan bilir.
    var onFocus: (() -> Void)?
    /// Metin görünümünün kimliği: menü komutu klavye odağındaki editörü
    /// tanısın diye (API Client ⌘F, `AppState.findInAPIClient`).
    var paneIdentifier: String?
    /// Verilirse kullanıcının değişiklikleri bu sınırlarla denetlenir.
    var limits: EditorLimits?
    /// İmleç değişince (satır, sütun; 1'den başlar). Workbench alt bilgisi.
    var onCursorChange: ((Int, Int) -> Void)?
    /// Değiştikçe editör odak alır (imleç yanıp söner). Workbench araç,
    /// sekme ya da mod değişince artırır; ilk kurulumda da uygulanır.
    var focusRequest: Int?

    /// Yazı boyutu (⌘+ / ⌘− / ⌘0, bkz. `EditorZoom`): tüm editörler ortak.
    @AppStorage(EditorZoom.key) private var fontSize = EditorZoom.standard

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        // Katlı bölge özetini ("… 30 keys") çizen yerleşim yöneticisi.
        textView.textContainer?.replaceLayoutManager(FoldingLayoutManager())
        textView.delegate = context.coordinator
        textView.identifier = paneIdentifier.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
        textView.font = EditorZoom.font(fontSize)
        context.coordinator.fontSize = fontSize
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

        if let folding {
            // Gutter: satır numaraları + katlama okları.
            let gutter = EditorGutter(scrollView: scrollView, textView: textView)
            gutter.fontSize = EditorZoom.gutterSize(fontSize)
            gutter.onToggleFold = { [weak coordinator = context.coordinator] line in
                coordinator?.toggleFold(line: line, in: textView)
            }
            scrollView.verticalRulerView = gutter
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            // Ruler kendi ayraç çizgisini kendi sınırlarının DIŞINA taşıyordu:
            // çizgi istek adının altından başlayıp üstteki satırların üzerinden
            // geçiyordu. Katman kırpması bunu editörün içinde tutuyor.
            scrollView.wantsLayer = true
            scrollView.layer?.masksToBounds = true
            textView.layoutManager?.delegate = context.coordinator.foldingDelegate
            context.coordinator.gutter = gutter
            context.coordinator.controller = folding
            folding.collapse = { [weak coordinator = context.coordinator] in
                coordinator?.collapseAll(in: textView)
            }
            folding.expand = { [weak coordinator = context.coordinator] in
                coordinator?.expandAll(in: textView)
            }
        }

        if let search {
            context.coordinator.search = search
            search.apply = { [weak coordinator = context.coordinator] in
                coordinator?.runSearch(in: textView)
            }
            search.move = { [weak coordinator = context.coordinator] forward in
                coordinator?.stepSearch(forward: forward, in: textView)
            }
            search.clear = { [weak coordinator = context.coordinator] in
                coordinator?.clearSearch(in: textView)
            }
            // Sekme değiştirince (Body <-> Headers) editör baştan kuruluyor;
            // açık bir arama varsa vurgular geri gelmeli. Burada doğrudan
            // çağırmak SwiftUI güncellemesinin İÇİNDE @Published yazmak olurdu.
            if search.isActive {
                DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                    coordinator?.runSearch(in: textView, reveal: false)
                }
            }
        }

        context.coordinator.textChanged(textView)
        // Kaydırdıkça yeni görünen bölge boyanır.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: scrollView, textView: textView)
        return scrollView
    }

    /// Editör kaldırılırken geri alma kayıtları da gider. (Kendi yığını
    /// olduğu için zaten koordinatörle birlikte yok olur; açıkça temizlemek
    /// AppKit'in yığını bir an daha tutması ihtimaline karşı.)
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.undoManager.removeAllActions()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        if textView.string != text, let limits, WorkbenchLimits.isTooLargeForEditor(text, maxBytes: limits.maxDisplayBytes) {
            // Sınırlı editöre sığmayan metin programla da yazılmaz: kapı
            // yapıştırmayı engelleyip metni duruma verdiğinde SwiftUI, editörü
            // açıklamayla değiştirmeden önce bir güncelleme daha yapıyor ve
            // aynı dev metni buradan editöre yazıyordu (ölçüldü: 5 MB'ta 3 sn).
        } else if textView.string != text {
            // Programatik değişim (ör. Beautify): metni değiştir, yeniden boya.
            // Geri alma kayıtları eski metnin aralıklarını gösteriyor; bırakılsa
            // ⌘Z var olmayan aralığı geri almaya çalışırdı. Temizlenir.
            context.coordinator.undoManager.removeAllActions()
            textView.string = text
            context.coordinator.textChanged(textView)
        } else if context.coordinator.lastLanguage != language {
            context.coordinator.textChanged(textView)
        }
        context.coordinator.markError(at: errorOffset, in: textView)
        if let focusRequest, focusRequest != context.coordinator.appliedFocusRequest {
            context.coordinator.appliedFocusRequest = focusRequest
            // Bir sonraki turda: ilk kurulumda görünüm henüz pencerede değil.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window, window.firstResponder !== textView else { return }
                window.makeFirstResponder(textView)
            }
        }
        if context.coordinator.fontSize != fontSize {
            context.coordinator.applyFontSize(fontSize, to: textView)
        }
    }

    /// `@MainActor`: bu sınıfın tüm çağrıları AppKit'ten gelir (delegate'ler,
    /// gutter tıklaması, SwiftUI güncellemesi) — hepsi ana thread'dedir.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Editörün KENDİ geri alma yığını.
        ///
        /// Pencerenin ortak yığınını kullanmak çökertiyordu (2026-10-18,
        /// EXC_BAD_ACCESS `-[_NSUndoStack popAndInvoke]` → `_undoRedoTextOperation:`):
        /// editör kaldırılınca (sekme/araç/mod değişimi, Text↔Tree) kayıtları
        /// ortak yığında kalıyor, ⌘Z silinmiş metin görünümüne mesaj
        /// gönderiyordu. Kendi yığını editörle birlikte yaşar ve ölür; bir
        /// editördeki ⌘Z başka editörün yazısını da geri almaz.
        let undoManager = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        var parent: CodeEditor
        /// Editörün şu an kullandığı yazı boyutu.
        var fontSize = EditorZoom.standard
        var lastLanguage: CodeLanguage?
        /// Uygulanmış son odak isteği (`CodeEditor.focusRequest`).
        var appliedFocusRequest: Int?
        private var scrollObserver: NSObjectProtocol?
        /// Gutter ve katlama durumu yalnızca `folding` verildiğinde kurulur.
        var gutter: EditorGutter?
        var controller: CodeFoldingController?
        /// Arama yalnızca `search` verildiğinde çalışır.
        var search: EditorSearchController?
        private var matches: [NSRange] = []
        private var currentMatch: Int?
        private var regions: [FoldRegion] = []
        private var foldedLines: Set<Int> = []
        /// Katlanan aralıkları çizimden düşüren delege (ayrı sınıf: testli).
        let foldingDelegate = FoldingLayoutDelegate()
        private var regionWork: DispatchWorkItem?

        private var markedErrorRange: NSRange?
        private var markedErrorOffset: Int?

        /// Hata satırını işaretler; konum değişmediyse dokunmaz (her
        /// güncellemede yeniden kaydırmak kullanıcının kaydırmasını ezerdi).
        func markError(at offset: Int?, in textView: NSTextView) {
            guard offset != markedErrorOffset || (offset != nil && markedErrorRange == nil) else { return }
            guard let layoutManager = textView.layoutManager else { return }
            if let previous = markedErrorRange, NSMaxRange(previous) <= (textView.string as NSString).length {
                layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: previous)
                layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: previous)
            }
            markedErrorRange = nil
            markedErrorOffset = offset
            let text = textView.string as NSString
            guard let offset, text.length > 0 else { return }
            let line = text.lineRange(for: NSRange(location: min(max(offset, 0), text.length - 1), length: 0))
            layoutManager.addTemporaryAttributes(
                [.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                 .underlineColor: NSColor.systemRed],
                forCharacterRange: line
            )
            markedErrorRange = line
            textView.scrollRangeToVisible(line)
        }

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        deinit {
            regionWork?.cancel()
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if let onCursorChange = parent.onCursorChange {
                let position = Self.cursorPosition(in: textView)
                onCursorChange(position.line, position.column)
            }
            guard textView.window?.firstResponder === textView else { return }
            parent.onFocus?()
        }

        /// Satır: imleçten önceki satır sonu sayısı + 1; sütun: satır başından
        /// karakter. Büyük metinde (4 MB) imleç hareketi başına birkaç ms.
        static func cursorPosition(in textView: NSTextView) -> (line: Int, column: Int) {
            let text = textView.string as NSString
            let location = min(textView.selectedRange().location, text.length)
            let prefix = text.substring(to: location) as NSString
            let line = max(1, TextStats.lineCount(prefix))
            let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
            return (line, location - lineStart + 1)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let limits = parent.limits, let text else { return true }
            let current = textView.string as NSString
            let resultLength = current.length - range.length + (text as NSString).length
            if WorkbenchLimits.mayExceed(utf16Length: resultLength, limit: limits.maxBytes) {
                let bytes = WorkbenchLimits.resultingBytes(of: current, replacing: range, with: text)
                if bytes > limits.maxBytes {
                    limits.onRejected(.tooLarge(bytes: bytes))
                    return false
                }
            }
            // Satır sınırı. Metin `maxLines` karakterden kısaysa sınıra
            // ulaşamaz, sayılmaz. Uzunsa yalnızca satır sonu ekleyen ya da metni
            // BÜYÜTEN değişiklikte sayılır (silme serbest): sınırdaki metne hiçbir
            // ekleme yapılmaz.
            if resultLength + 1 > limits.maxLines {
                let addsBreak = text.contains(where: \.isNewline)
                let grows = (text as NSString).length > range.length
                if addsBreak || grows {
                    let currentLines = TextStats.lineCount(current)
                    let resultLines = addsBreak
                        ? TextStats.lineCount(current.replacingCharacters(in: range, with: text) as NSString)
                        : currentLines
                    if resultLines > limits.maxLines {
                        limits.onRejected(.tooManyLines(resultLines))
                        return false
                    }
                    if grows, currentLines >= limits.maxLines {
                        limits.onRejected(.atLineLimit)
                        return false
                    }
                }
            }
            // Uzun satır yalnızca büyük eklemede (yapıştırma, sürükleme) aranır:
            // yazarak 1 MB'lık satır oluşmaz, her tuşta tüm metni taramaya değmez.
            if (text as NSString).length >= 4096,
               WorkbenchLimits.mayExceed(utf16Length: resultLength, limit: limits.maxLineBytes) {
                let result = current.replacingCharacters(in: range, with: text)
                if WorkbenchLimits.hasLine(longerThan: limits.maxLineBytes, in: result) {
                    limits.onLongLine(result)
                    return false
                }
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // ANINDA boyanır, gecikme yok. Eskiden 120 ms ertelenirdi: tüm belge
            // taranacağı için her tuşta yapılamazdı. Yapıştırılan JSON önce
            // renksiz görünüp sonra renklenmesinin sebebi buydu. Artık iş
            // yalnızca görünen bölge kadar (~1,5 ms), ertelemeye gerek yok.
            colorizeVisible(textView)
            // Satır numaraları ve katlanabilir bölgeler de tazelenmeli: metin
            // yalnızca kurulumda hesaplanıyordu, yazarak/yapıştırarak gelen
            // gövdede gutter tek satırda kalıyordu.
            //
            // Renklendirmenin aksine bu iş METİN BOYUTUYLA büyüyor (ölçüm:
            // 82 KB'de 3,4 ms, 858 KB'de 15,4 ms), yani her tuşta yapılamaz.
            // Yazım durduğunda bir kez koşar.
            scheduleHeavyRefresh(textView)
        }

        /// Metin (ya da dil) değişti: temel biçim tüm belgeye, renk görünen bölgeye.
        /// ⌘+ / ⌘−: yazı ve satır numaraları yeniden boyutlanır, renk korunur.
        func applyFontSize(_ size: Double, to textView: NSTextView) {
            fontSize = size
            textView.font = EditorZoom.font(size)
            if let storage = textView.textStorage {
                SyntaxHighlighter.applyBaseAttributes(storage, font: EditorZoom.font(size))
            }
            colorizeVisible(textView)
            gutter?.fontSize = EditorZoom.gutterSize(size)
        }

        func textChanged(_ textView: NSTextView) {
            lastLanguage = parent.language
            guard let storage = textView.textStorage else { return }
            SyntaxHighlighter.applyBaseAttributes(storage, font: EditorZoom.font(fontSize))
            colorizeVisible(textView)
            refreshRegions(textView)
            // Metin dışarıdan değişmiş olabilir (Beautify, yeni yanıt): eski
            // eşleşmeler artık yanlış yeri gösteriyor. Ertelenerek yapılıyor,
            // çünkü buraya SwiftUI güncellemesinin içinden de giriliyor ve
            // orada @Published yazmak güncelleme döngüsü açar.
            scheduleHeavyRefresh(textView)
        }

        // MARK: - Katlama

        /// Metin boyutuyla büyüyen işleri (katlanabilir bölge taraması ve
        /// arama) yazım durduktan sonra TEK sefere indirir.
        ///
        /// Arama burada eşleşmeyi seçmez (`reveal: false`): kullanıcı editörde
        /// yazarken imleci en yakın eşleşmeye kaydırmak yazdığı yeri elinden
        /// almak olurdu. Yalnızca sayı ve vurgular tazelenir.
        private func scheduleHeavyRefresh(_ textView: NSTextView) {
            guard gutter != nil || search?.isActive == true else { return }
            regionWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                if self.gutter != nil { self.refreshRegions(textView) }
                if self.search?.isActive == true { self.runSearch(in: textView, reveal: false) }
            }
            regionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// Metin değişince katlanabilir bölgeler yeniden bulunur.
        /// Düzenlenebilir editörde katlar açılır: gizli metnin içine yazmak
        /// kullanıcıyı şaşırtır, kaybolan aralıkları takip etmek de kırılgandır.
        func refreshRegions(_ textView: NSTextView) {
            guard let gutter, let controller else { return }
            regions = parent.language.foldableRegions(in: textView.string)
            if parent.isEditable, !foldedLines.isEmpty {
                foldedLines.removeAll()
            } else {
                // Artık bölge başlatmayan satırların katı düşer.
                foldedLines = foldedLines.filter { line in regions.contains { $0.openLine == line } }
            }
            gutter.foldableLines = Set(regions.map(\.openLine))
            gutter.refresh(text: textView.string)
            // Yalnızca gerçekten değiştiyse yayınla: her tazelemede yayın
            // yapmak SwiftUI güncellemesi içinde güncelleme tetikliyor.
            if controller.gutterWidth != gutter.ruleThickness {
                controller.gutterWidth = gutter.ruleThickness
            }
            controller.isAvailable = !regions.isEmpty
            applyFolding(textView)
        }

        func toggleFold(line: Int, in textView: NSTextView) {
            if foldedLines.contains(line) { foldedLines.remove(line) } else { foldedLines.insert(line) }
            applyFolding(textView)
        }

        func collapseAll(in textView: NSTextView) {
            // TÜM bölgeler (iç içe olanlar dahil): dış blok açılınca içindekiler
            // katlı kalır, kullanıcı adım adım açar (kullanıcı isteği,
            // 2026-10-19; eskiden yalnızca en dıştakiler katlanıyordu ve tek
            // açışta her şey açılıyordu).
            foldedLines = Set(regions.map(\.openLine))
            applyFolding(textView)
        }

        func expandAll(in textView: NSTextView) {
            foldedLines.removeAll()
            applyFolding(textView)
        }

        /// Gizli aralıklar DEĞİŞMEDİYSE hiçbir şey geçersizleştirilmez: metin
        /// düzenlemesini yerleşim yöneticisi zaten kendisi işler.
        ///
        /// 2026-10-18 (ölçüldü): burası her metin değişikliğinde, hiç kat
        /// yokken bile tüm belgenin yerleşimini geçersizleştirip TÜM görünümü
        /// çizime işaretliyordu; bu, görünmeyen metnin de hemen yerleşmesini
        /// zorluyordu. Tek satırlık (sıkıştırılmış) metinde süre kareyle
        /// büyüyordu: 512 KB'ta 3 sn, 5 MB'ta 10 dakikadan uzun donma.
        private func applyFolding(_ textView: NSTextView) {
            // Yalnızca görünür (başka katlının içinde olmayan) katlı bölgeler
            // gizlenir ve özet alır: iç içe olanlar dıştakiyle zaten gizli.
            let visibleFolded = FoldRegion.outermost(regions.filter { foldedLines.contains($0.openLine) })
            let hidden = visibleFolded.map(\.hiddenRange)
            gutter?.foldedLines = foldedLines
            controller?.hasFolded = !foldedLines.isEmpty
            guard hidden != foldingDelegate.hiddenRanges else { return }
            let text = textView.string as NSString
            foldingDelegate.placeholders = Dictionary(uniqueKeysWithValues: visibleFolded.map {
                ($0.hiddenRange.location, $0.summary(in: text))
            })
            foldingDelegate.placeholderFont = NSFont.monospacedSystemFont(ofSize: max(fontSize - 2, 9), weight: .regular)
            foldingDelegate.hiddenRanges = hidden

            guard let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            // Yerleşim doğru olsa da görünüm eski alanı koruyup yeniden
            // çizmiyordu: katlanmış satırda kapanış parantezi ekrana gelmiyordu.
            // Yalnızca GÖRÜNEN alan: tüm görünüm, tüm metni yerleştirmeye zorlar.
            textView.setNeedsDisplay(textView.visibleRect)
            gutter?.needsDisplay = true
            // Yerleşim geçersizleştiği için geçici öznitelikler (arama
            // vurguları) silindi; yeniden konuyor.
            applySearchHighlights(textView)
        }

        func colorizeVisible(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            SyntaxHighlighter.colorize(storage, language: parent.language, range: visibleRange(of: textView))
            // Kaydırınca yeni görünen satırlardaki eşleşmeler de boyanmalı.
            applySearchHighlights(textView)
        }

        // MARK: - Arama

        /// Sorguyu uygular. `reveal` açıkken bulunan eşleşme seçilip ekrana
        /// getirilir; kapalıyken yalnızca sayı ve vurgular tazelenir.
        func runSearch(in textView: NSTextView, reveal shouldReveal: Bool = true) {
            guard let search else { return }
            guard search.isActive else {
                clearSearch(in: textView)
                return
            }
            let result = TextSearch.find(search.query, in: textView.string, options: search.options)
            matches = result.ranges
            // Belgenin başına dönmek yerine imlecin olduğu yerden devam:
            // yazarken bakılan yer kaybolmasın.
            currentMatch = TextSearch.firstIndex(
                atOrAfter: textView.selectedRange().location,
                in: matches
            )
            search.report(result, currentIndex: currentMatch)
            if shouldReveal {
                reveal(in: textView)
            } else {
                applySearchHighlights(textView)
            }
        }

        func stepSearch(forward: Bool, in textView: NSTextView) {
            guard let search, !matches.isEmpty else { return }
            currentMatch = TextSearch.step(from: currentMatch, count: matches.count, forward: forward)
            search.reportCursor(currentMatch)
            reveal(in: textView)
        }

        func clearSearch(in textView: NSTextView) {
            matches = []
            currentMatch = nil
            applySearchHighlights(textView)
        }

        private func reveal(in textView: NSTextView) {
            if let index = currentMatch, matches.indices.contains(index) {
                let range = matches[index]
                expandFolds(containing: range, in: textView)
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
            }
            applySearchHighlights(textView)
        }

        /// Eşleşme katlanmış bir bloğun içindeyse blok açılır. Açılmazsa
        /// "17 sonuç" yazıp ekranda hiçbir şey göstermemiş oluruz.
        private func expandFolds(containing range: NSRange, in textView: NSTextView) {
            guard !foldedLines.isEmpty else { return }
            let hiding = regions.filter {
                foldedLines.contains($0.openLine) && NSLocationInRange(range.location, $0.hiddenRange)
            }
            guard !hiding.isEmpty else { return }
            for region in hiding { foldedLines.remove(region.openLine) }
            applyFolding(textView)
        }

        /// Vurgular metin depolamasına DEĞİL, yerleşim yöneticisinin geçici
        /// özniteliklerine yazılır. İki sebep: depolamaya dokunmak
        /// düzenlenebilir gövdede metni değişmiş saydırır, ve renklendirme
        /// zaten aynı `foregroundColor` özniteliğini kullandığı için ikisi
        /// birbirini ezerdi.
        ///
        /// Boyama yalnızca görünen aralıkta (docs/UI-KURALLARI.md 5): 2.000
        /// eşleşmenin tamamını boyamanın ekranda karşılığı yok.
        private func applySearchHighlights(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            guard !matches.isEmpty else { return }

            let visible = visibleRange(of: textView)
            for (index, range) in matches.enumerated()
            where NSIntersectionRange(range, visible).length > 0 {
                if index == currentMatch {
                    layoutManager.addTemporaryAttributes(
                        [
                            .backgroundColor: Theme.searchCurrentMatch,
                            .foregroundColor: Theme.searchCurrentMatchText,
                        ],
                        forCharacterRange: range
                    )
                } else {
                    layoutManager.addTemporaryAttributes(
                        [.backgroundColor: Theme.searchMatch],
                        forCharacterRange: range
                    )
                }
            }
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
