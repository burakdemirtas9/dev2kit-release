import AppKit
import SwiftUI
import Dev2KitCore

enum CodeLanguage: Equatable {
    case plain
    case json
    case markup      // XML / HTML
    case javascript

    /// Katlanabilir mi ve hangi tarayıcıyla.
    ///
    /// JSON/JS parantezle, XML-HTML etiketle katlanır; düz metinde katlanacak
    /// bir yapı yok. Tarayıcı seçimi burada duruyor ki dil eklendiğinde
    /// derleyici eksik kalan yeri göstersin.
    func foldableRegions(in text: String) -> [FoldRegion] {
        switch self {
        case .json, .javascript: return JSONFolding.regions(in: text)
        case .markup: return MarkupFolding.regions(in: text)
        case .plain: return []
        }
    }

    var supportsFolding: Bool {
        self != .plain
    }

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

        if let folding {
            // Gutter: satır numaraları + katlama okları.
            let gutter = EditorGutter(scrollView: scrollView, textView: textView)
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
        if textView.string != text {
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
        var lastLanguage: CodeLanguage?
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
            guard let textView = notification.object as? NSTextView, textView.window?.firstResponder === textView else { return }
            parent.onFocus?()
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
        func textChanged(_ textView: NSTextView) {
            lastLanguage = parent.language
            guard let storage = textView.textStorage else { return }
            SyntaxHighlighter.applyBaseAttributes(storage, font: CodeEditor.font)
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
            // Yalnızca en dıştakiler: içerdekileri kapatmanın görünür etkisi yok.
            foldedLines = Set(FoldRegion.outermost(regions).map(\.openLine))
            applyFolding(textView)
        }

        func expandAll(in textView: NSTextView) {
            foldedLines.removeAll()
            applyFolding(textView)
        }

        private func applyFolding(_ textView: NSTextView) {
            foldingDelegate.hiddenRanges = regions
                .filter { foldedLines.contains($0.openLine) }
                .map(\.hiddenRange)
            gutter?.foldedLines = foldedLines
            controller?.hasFolded = !foldedLines.isEmpty

            guard let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            // Yerleşim doğru olsa da görünüm eski alanı koruyup yeniden
            // çizmiyordu: katlanmış satırda kapanış parantezi ekrana gelmiyordu.
            textView.needsDisplay = true
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
