import Foundation
import Dev2KitCore

/// Bir editörün arama durumunu SwiftUI tarafından yönetmek için köprü.
///
/// `CodeFoldingController` ile aynı desen: arama çubuğu editörün DIŞINDA
/// duruyor, editör kendini buraya kaydediyor, çubuk doğrudan çağırıyor.
///
/// **Her editörün kendi örneği vardır.** İstek gövdesi ve yanıt birbirinden
/// bağımsız arar: ayrı sorgu, ayrı seçenek, ayrı imleç. Ortak olan kural
/// (`TextSearch`), durum değil.
@MainActor
final class EditorSearchController: ObservableObject {
    /// Çubuk görünür mü.
    @Published private(set) var isPresented = false
    @Published var query = "" { didSet { queryChanged(from: oldValue) } }
    @Published var options = TextSearch.Options() { didSet { optionsChanged(from: oldValue) } }

    /// Editörün bildirdiği sonuç özeti. Aralıkların kendisi editörde kalır:
    /// 2.000 elemanlı bir diziyi yayınlamak her tuşta SwiftUI karşılaştırması
    /// demek olurdu.
    @Published private(set) var matchCount = 0
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isTruncated = false
    @Published private(set) var isInvalidPattern = false

    /// Editör kurulurken doldurur (`CodeEditor.makeNSView`). `fileprivate`
    /// değil çünkü editör ayrı dosyada; modül dışına zaten kapalı.
    var apply: (() -> Void)?
    var move: ((Bool) -> Void)?
    var clear: (() -> Void)?

    /// Editörün iş yapması gerekiyor mu. Çubuk kapalıyken ya da sorgu boşken
    /// metin taranmaz: arama açılmamış bir editöre maliyet bindirmeyelim.
    var isActive: Bool { isPresented && !query.isEmpty }

    /// Regex kipinde her tuşta arama YAPILMAZ.
    ///
    /// `NSRegularExpression`'ın zaman sınırı yok; yarım yazılmış bir kalıp
    /// (`(a+)+b` gibi) geri izleme patlamasıyla ana thread'i kilitleyebilir.
    /// Düz metinde böyle bir risk olmadığı için orada anında aranır.
    var runsIncrementally: Bool { !options.isRegex }

    // MARK: - Çubuk

    /// Çubuk zaten açıkken tekrar açmak da imleci kutuya geri getirmeli:
    /// menü kısayoluna ikinci kez basmak "hiçbir şey olmadı" gibi durmasın.
    /// Sayaç, sidebar aramasındaki `searchFocusRequest` ile aynı desen.
    @Published private(set) var focusRequest = 0

    func open() {
        isPresented = true
        focusRequest += 1
        apply?()
    }

    /// Kapatınca vurgular silinir ama sorgu durur: kullanıcı aynı şeyi
    /// aramaya devam etmek için yeniden yazmak zorunda kalmasın.
    func close() {
        isPresented = false
        clear?()
        matchCount = 0
        currentIndex = nil
        isTruncated = false
        isInvalidPattern = false
    }

    func toggle() {
        if isPresented { close() } else { open() }
    }

    // MARK: - Arama

    /// Arama kutusunda ⏎. Regex kipinde aramayı BAŞLATIR, düz metinde zaten
    /// arama yapılmış olduğu için sonraki eşleşmeye geçer.
    func submit() {
        if runsIncrementally { move?(true) } else { apply?() }
    }

    func next() { move?(true) }
    func previous() { move?(false) }

    /// Editör → çubuk. Tarama bittiğinde çağrılır.
    func report(_ result: TextSearch.Result, currentIndex: Int?) {
        matchCount = result.count
        isTruncated = result.isTruncated
        isInvalidPattern = result.isInvalidPattern
        self.currentIndex = currentIndex
    }

    /// Editör → çubuk, yalnızca imleç değişince: sonraki/önceki eşleşmeye
    /// geçmek metni yeniden taramayı gerektirmez.
    func reportCursor(_ index: Int?) {
        currentIndex = index
    }

    // MARK: - Değişiklikler

    private func queryChanged(from oldValue: String) {
        guard query != oldValue, isPresented else { return }
        if query.isEmpty {
            clear?()
            report(.none, currentIndex: nil)
        } else if runsIncrementally {
            apply?()
        }
    }

    private func optionsChanged(from oldValue: TextSearch.Options) {
        guard options != oldValue, isPresented, !query.isEmpty else { return }
        // Seçenek değişimi kullanıcının açık isteğidir; regex kipinde de
        // hemen uygulanır (kalıp zaten tamamlanmış durumda).
        apply?()
    }
}
