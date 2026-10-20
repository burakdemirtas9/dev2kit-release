import Foundation
import Observation
import Dev2KitCore

/// Workbench'te bir sekme: kendi girdisi, eylemi, seçenekleri.
struct WorkbenchDocument: Identifiable, Equatable {
    let id = UUID()
    /// Sekme adındaki numara ("JSON 2"): açık sekmelerde boşta olan en
    /// küçük sayı; hepsi kapanınca yeniden 1'den başlar (sayaç tutulmaz).
    let number: Int
    var input = ""
    var actionID: String?
    var options = WorkbenchOptions()
    var outputMode: WorkbenchState.OutputMode = .text
    /// Girdi editörde gösterilemeyecek kadar büyük ya da 1 MB'tan uzun
    /// satırlı (`WorkbenchLimits`): saklanır ve araçlar çalışır, editör yerine
    /// açıklama gösterilir. Girdi her değiştiğinde hesaplanır.
    var inputTooLargeForEditor = false
}

/// Workbench'in durumu. `AppState`'ten AYRI: API Client'ın durumuyla hiçbir
/// ortak alanı yok; aynı sınıfa konsa yeni yeniden şişerdi (docs/V2.md).
///
/// Bellek politikası (docs/V2.md "Güvenlik ve bellek"):
/// - Girdiler yalnızca bellekte (sekme başına); diske, geçmişe yazılmaz,
///   pano otomatik okunmaz.
/// - Çıktı, doğrulama, istatistik ve ağaç YALNIZCA açık sekme için tutulur;
///   sekme ya da araç değişince bırakılır, açılınca yeniden hesaplanır
///   (araçlar saf fonksiyon).
/// - Ağır iş ana thread dışında; eski bir çalıştırmanın sonucu yenisinin
///   üstüne yazılmaz (nesil sayacı, UI-KURALLARI §4b).
///
/// Ölçüm (M4, release, 2026-10-18): JSON okuma ~20 ms/MB, biçimlendirme
/// ~150 ms/MB, ağaç modeli metnin ~3 katı bellek. Eşikler buna göre.
@Observable
@MainActor
final class WorkbenchState {
    /// Bu boyutun üstünde girdi değişince otomatik çalışmaz, "Run" beklenir.
    static let autoRunLimit = 1_048_576
    /// Bu boyutun üstünde sözdizimi renklendirmesi kapanır.
    static let highlightLimit = 5 * 1_048_576
    static let debounce: Duration = .milliseconds(300)
    /// Temizledikten sonra "Undo" düğmesinin görünür kaldığı süre.
    static let undoWindow: Duration = .seconds(8)

    enum OutputMode: String, CaseIterable, Identifiable {
        case text
        case tree
        var id: String { rawValue }
        var title: String { self == .text ? L10n.t("body.kind.text") : L10n.t("wb.tree") }
    }

    enum Pane { case input, output }

    var searchQuery = ""

    /// Diff Checker'ın durumu: ayrı sınıf (iki girdi, kendi kuralları).
    @ObservationIgnored let diff = DiffCheckerState()

    var showsDiffChecker: Bool { selectedToolID == WorkbenchCatalog.diffCheckerID }

    /// Açık araç. Hangi aracın açık olduğu hassas değil; hatırlanır.
    private(set) var selectedToolID: String = UserDefaults.standard.string(forKey: "workbenchTool")
        ?? WorkbenchCatalog.all[0].id

    private var documentsByTool: [String: [WorkbenchDocument]] = [:]
    private var selectedDocumentByTool: [String: UUID] = [:]

    // MARK: Açık sekmenin sonucu

    private(set) var output = ""
    /// Son çalıştırmanın süresi; çıktı bölmesinin alt bilgisinde gösterilir.
    private(set) var lastRunDuration: Duration?
    /// Girdideki imleç (satır, sütun; 1'den başlar): girdi bölmesinin alt
    /// bilgisinde. Hata mesajındaki satırı bulmayı kolaylaştırır.
    private(set) var inputCursor: CursorPosition?

    struct CursorPosition: Equatable {
        let line: Int
        let column: Int
    }

    /// Çıktıda tıklanan yer (alt bilgide). Çıktı yeniden hesaplanınca düşer.
    private(set) var outputCursor: CursorPosition?

    func updateOutputCursor(line: Int, column: Int) {
        let position = CursorPosition(line: line, column: column)
        if position != outputCursor { outputCursor = position }
    }

    func updateInputCursor(line: Int, column: Int) {
        let position = CursorPosition(line: line, column: column)
        if position != inputCursor { inputCursor = position }
    }
    /// Çıktı editörde gösterilemeyecek kadar büyük ya da uzun satırlı
    /// (ör. 1 MB'ı aşan Minify çıktısı): yalnızca kopyalanabilir.
    private(set) var outputHiddenFromEditor = false
    private(set) var actionIssue: WorkbenchIssue?
    /// Eylemin kısa özeti ("3 matches"); yoksa `nil`.
    private(set) var outputSummary: String?
    private(set) var validation: WorkbenchValidation = .empty
    private(set) var tree: JSONTreeNode?
    private(set) var inputStats = TextStats.empty
    private(set) var outputStats = TextStats.empty
    private(set) var isRunning = false
    /// Büyük girdide son çalıştırmadan beri girdi değişti mi.
    private(set) var isStale = false

    /// Çıktı kalemle düzenlemeye açıldı mı; düzenlenmiş metin.
    private(set) var isEditingOutput = false
    private(set) var editedOutput: String?

    /// Temizlenen girdi; kısa süre "Undo" ile geri alınabilir.
    private(set) var clearedInput: (documentID: UUID, text: String)?
    @ObservationIgnored private var undoTask: Task<Void, Never>?

    /// ⌘F: odaktaki bölmede arama. Sayaç: aynı bölmede tekrar basmak da
    /// gözlemlenebilir olsun (sidebar aramasıyla aynı desen).
    private(set) var focusedPane: Pane = .input
    private(set) var searchRequest = 0

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?

    // MARK: - Erişimciler

    var tool: WorkbenchTool { WorkbenchCatalog.tool(id: selectedToolID) ?? WorkbenchCatalog.all[0] }

    var documents: [WorkbenchDocument] {
        documentsByTool[tool.id] ?? []
    }

    var document: WorkbenchDocument {
        let docs = documents
        return docs.first { $0.id == selectedDocumentByTool[tool.id] } ?? docs.first ?? WorkbenchDocument(number: 1)
    }

    var action: WorkbenchAction { tool.action(id: document.actionID) }
    var options: WorkbenchOptions { document.options }
    var showsTree: Bool { action.supportsTree && document.outputMode == .tree }
    var isLargeInput: Bool { inputStats.bytes > Self.autoRunLimit }
    var highlightsSyntax: Bool { inputStats.bytes <= Self.highlightLimit }
    /// Ekranda gösterilen çıktı: kalemle düzenlendiyse o hali.
    var displayedOutput: String { editedOutput ?? output }

    init() {
        ensureDocument()
    }

    /// Açık sekmenin girdisi. Yazdıkça kısa gecikmeyle çalışır (büyük girdide
    /// "Run" beklenir).
    var input: String {
        get { document.input }
        set {
            storeInput(newValue)
            if clearedInput != nil, !newValue.isEmpty { dismissUndo() }
            inputStats = TextStats(bytes: newValue.utf8.count, lines: inputStats.lines, characters: inputStats.characters)
            if isLargeInput {
                runTask?.cancel()
                isStale = true
            } else {
                schedule(debounced: true)
            }
        }
    }

    // MARK: - Araç ve sekme

    /// Araç, sekme ya da mod değişince girdi editörü odak alır: kullanıcı
    /// hemen yapıştırıp yazabilsin (kullanıcı isteği, 2026-10-18).
    private(set) var inputFocusRequest = 0

    func requestInputFocus() {
        if showsDiffChecker { diff.requestFocus() } else { inputFocusRequest += 1 }
    }

    func select(toolID: String) {
        guard toolID != selectedToolID,
              WorkbenchCatalog.tool(id: toolID) != nil || toolID == WorkbenchCatalog.diffCheckerID else { return }
        selectedToolID = toolID
        UserDefaults.standard.set(toolID, forKey: "workbenchTool")
        guard !showsDiffChecker else { diff.requestFocus(); return }
        ensureDocument()
        documentChanged()
    }

    func select(documentID: UUID) {
        guard documentID != document.id, documents.contains(where: { $0.id == documentID }) else { return }
        selectedDocumentByTool[tool.id] = documentID
        documentChanged()
    }

    func newDocument() {
        // Sekmeler yalnızca JSON'da (kullanıcı kararı, 2026-10-19).
        guard tool.supportsTabs else { return }
        let doc = WorkbenchDocument(number: takeNumber(), options: tool.defaultOptions)
        documentsByTool[tool.id, default: []].append(doc)
        selectedDocumentByTool[tool.id] = doc.id
        documentChanged()
    }

    /// Sekmeyi kapatır; son sekme kapanınca boş bir sekme açılır (araç
    /// ekranı hiçbir zaman sekmesiz kalmaz). İçi dolu sekmede onayı arayüz alır.
    func closeDocument(_ id: UUID) {
        var docs = documents
        guard let index = docs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = id == document.id
        docs.remove(at: index)
        documentsByTool[tool.id] = docs
        if clearedInput?.documentID == id { dismissUndo() }
        if docs.isEmpty {
            ensureDocument()
        } else if wasSelected {
            selectedDocumentByTool[tool.id] = docs[min(index, docs.count - 1)].id
        }
        if wasSelected || docs.isEmpty { documentChanged() }
    }

    func title(of doc: WorkbenchDocument) -> String {
        "\(tool.title) \(doc.number)"
    }

    // MARK: - Eylem ve seçenekler

    func select(actionID: String) {
        mutateDocument { $0.actionID = actionID }
        // Ağaç yalnızca biçimlendirmede; başka eyleme geçince metne dönülür.
        if !action.supportsTree { mutateDocument { $0.outputMode = .text } }
        schedule(debounced: false)
    }

    func update(options: WorkbenchOptions) {
        mutateDocument { $0.options = options }
        schedule(debounced: false)
    }

    /// Sorgu satırı (JSONPath): yazarken her tuşta değil, kısa beklemeyle.
    func update(query: String) {
        guard query != options.query else { return }
        mutateDocument { $0.options.query = query }
        schedule(debounced: true)
    }

    /// Boş girdiye aracın örneğini koyar (varsa örneğe uyan seçeneklerle).
    func loadSample() {
        guard !tool.sampleInput.isEmpty else { return }
        if let apply = tool.sampleOptions {
            var updated = options
            apply(&updated)
            mutateDocument { $0.options = updated }
        }
        input = tool.sampleInput
        schedule(debounced: false)
    }

    /// Girdiyi yerinde biçimlendirir (aracın `inputFormatter`'ı). Arka planda:
    /// büyük JSON ana iş parçacığını dondurmasın. Geçersiz girdide dokunulmaz;
    /// hata zaten doğrulama satırında konumuyla görünüyor.
    func formatInput() {
        guard let formatter = tool.inputFormatter, !input.isEmpty else { return }
        let text = input
        let options = options
        let documentID = document.id
        Task { [weak self] in
            let formatted = await BackgroundWork.run { try? formatter(text, options) }
            guard let self, let formatted, self.document.id == documentID, self.input == text else { return }
            self.input = formatted
        }
    }

    func select(outputMode: OutputMode) {
        mutateDocument { $0.outputMode = outputMode }
        // Ağaçtan çıkınca model bırakılır: metnin ~3 katı yer tutuyor.
        if outputMode == .text { tree = nil }
        schedule(debounced: false)
    }

    // MARK: - Çıktı düzenleme

    /// Kalem: çıktıyı düzenlemeye açar/kapatır. Kapatınca düzenleme durur
    /// ama metin kalır; girdi ya da seçenek değişince çıktı yeniden
    /// hesaplanır ve düzenleme bırakılır.
    func toggleOutputEditing() {
        guard tool.allowsOutputEditing, !outputHiddenFromEditor else { return }
        // Düzenleme girdiye yansır: girdi sınırlarını aşan çıktı düzenlenmez.
        if !isEditingOutput, let issue = WorkbenchLimits.outputEditIssue(displayedOutput) {
            reportLimit(issue)
            return
        }
        isEditingOutput.toggle()
    }

    /// Çıktıdaki düzenleme girdiye de yansır (eylemin ters dönüşümüyle).
    /// Çıktı bu sırada YENİDEN HESAPLANMAZ: hesaplansa yazarken imleç
    /// zıplar, yazılan ezilirdi. Yalnızca doğrulama, ağaç ve istatistik
    /// tazelenir. Ters dönüşüm hata verirse (yazarken geçici olarak bozuk
    /// metin) girdiye dokunulmaz.
    func editOutput(_ text: String) {
        guard isEditingOutput else { return }
        editedOutput = text
        outputStats = TextStats(text)
        guard let reverse = action.reverse,
              let newInput = try? reverse(text, document.input, options),
              newInput != document.input else { return }
        storeInput(newInput)
        if clearedInput != nil { dismissUndo() }
        inputStats = TextStats(bytes: newInput.utf8.count, lines: inputStats.lines, characters: inputStats.characters)
        schedule(debounced: true, refreshOutput: false)
    }

    func useOutputAsInput() {
        let text = displayedOutput
        guard !text.isEmpty else { return }
        if let issue = WorkbenchLimits.outputEditIssue(text) {
            reportLimit(issue)
            return
        }
        input = text
    }

    // MARK: - Sınırlar (WorkbenchLimits)

    var inputHiddenFromEditor: Bool { document.inputTooLargeForEditor }

    /// Sınır nedeniyle yapılmayan değişikliğin açıklaması (durum çubuğunda,
    /// kırmızı). Bir süre sonra kendiliğinden kalkar.
    private(set) var limitNotice: String?
    @ObservationIgnored private var limitNoticeTask: Task<Void, Never>?

    func reportLimit(_ message: String) {
        limitNotice = message
        limitNoticeTask?.cancel()
        limitNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.limitNotice = nil
        }
    }

    /// Editöre yapıştırılan metinde 1 MB'tan uzun satır var: editöre girmedi,
    /// burada saklanır; girdi bölmesi editör yerine açıklama gösterir.
    func acceptInputHiddenFromEditor(_ text: String) {
        input = text
    }

    private func storeInput(_ text: String) {
        let hidden = WorkbenchLimits.isTooLargeForEditor(text)
        mutateDocument {
            $0.input = text
            $0.inputTooLargeForEditor = hidden
        }
    }

    // MARK: - Ağaçta değer düzenleme

    /// Ağaçta düzenlenen yaprak değeri girdiye yazar; girdi değiştiği için
    /// çıktı ve ağaç yeniden hesaplanır. Hata metnini döner (satırda gösterilir).
    @discardableResult
    func editTreeValue(at steps: [JSONPathStep], text: String) -> String? {
        do {
            input = try JSONTool.replacingValue(in: input, at: steps, with: text, options: options)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Kaydet

    /// ⌘S: Workbench diske YAZMAZ (docs/V2.md). Alışkanlıkla basan
    /// kullanıcıya içeriğin nerede durduğu söylenir.
    private(set) var saveNotice = false
    @ObservationIgnored private var saveNoticeTask: Task<Void, Never>?

    func save() {
        saveNotice = true
        saveNoticeTask?.cancel()
        saveNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.saveNotice = false
        }
    }

    // MARK: - Temizle / geri al

    func clearInput() {
        let text = input
        guard !text.isEmpty else { return }
        clearedInput = (document.id, text)
        input = ""
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.clearedInput = nil
        }
    }

    func undoClear() {
        guard let cleared = clearedInput, cleared.documentID == document.id else { return }
        dismissUndo()
        input = cleared.text
    }

    private func dismissUndo() {
        undoTask?.cancel()
        clearedInput = nil
    }

    // MARK: - Arama

    func focus(_ pane: Pane) {
        if focusedPane != pane { focusedPane = pane }
    }

    /// Menüdeki "Find" (⌘F) Workbench'teyken buraya gelir.
    func requestSearch() {
        searchRequest += 1
    }

    /// Büyük girdide elle çalıştırma.
    func runNow() {
        schedule(debounced: false, force: true)
    }

    /// Arayüz dili değişti: doğrulama mesajı ve özet yeni dilde yeniden
    /// üretilir. Büyük girdi kendiliğinden çalışmadığı için dokunulmaz;
    /// kalemle düzenlenen çıktı korunur (yalnızca doğrulama tazelenir).
    func languageChanged() {
        diff.languageChanged()
        guard !isLargeInput, !document.input.isEmpty else { return }
        schedule(debounced: false, refreshOutput: editedOutput == nil && !isEditingOutput)
    }

    // MARK: - İç işler

    private func ensureDocument() {
        if documents.isEmpty {
            let doc = WorkbenchDocument(number: takeNumber(), options: tool.defaultOptions)
            documentsByTool[tool.id] = [doc]
            selectedDocumentByTool[tool.id] = doc.id
        } else if !documents.contains(where: { $0.id == selectedDocumentByTool[tool.id] }) {
            selectedDocumentByTool[tool.id] = documents[0].id
        }
    }

    private func takeNumber() -> Int {
        let used = Set(documents.map(\.number))
        return (1...).first { !used.contains($0) } ?? 1
    }

    private func mutateDocument(_ change: (inout WorkbenchDocument) -> Void) {
        guard var docs = documentsByTool[tool.id], let index = docs.firstIndex(where: { $0.id == document.id }) else { return }
        change(&docs[index])
        documentsByTool[tool.id] = docs
    }

    /// Açık sekme değişti: önceki sonucun hepsi bırakılır (bellek), yenisi hesaplanır.
    private func documentChanged() {
        inputFocusRequest += 1
        output = ""
        lastRunDuration = nil
        inputCursor = nil
        outputCursor = nil
        outputHiddenFromEditor = false
        editedOutput = nil
        isEditingOutput = false
        tree = nil
        actionIssue = nil
        outputSummary = nil
        validation = .empty
        outputStats = .empty
        inputStats = TextStats(bytes: document.input.utf8.count, lines: 0, characters: 0)
        schedule(debounced: false, force: true)
    }

    /// `refreshOutput: false`: girdi çıktıdan güncellendi; eylem çalıştırılmaz,
    /// yalnızca doğrulama/ağaç/istatistik tazelenir, düzenlenen çıktı kalır.
    private func schedule(debounced: Bool, force: Bool = false, refreshOutput: Bool = true) {
        runTask?.cancel()
        generation += 1
        let current = generation
        // Yeni çalıştırma kalemle yapılan düzenlemenin üzerine yazar.
        if refreshOutput { editedOutput = nil }
        let text = document.input
        guard force || !isLargeInput else {
            isStale = true
            return
        }
        let tool = tool
        let action = action
        let options = options
        let wantsTree = showsTree
        isRunning = true
        runTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: Self.debounce)
                if Task.isCancelled { return }
            }
            // Büyük yığın: derin girdide yığın taşmasın (BackgroundWork).
            let result = await BackgroundWork.run {
                let start = ContinuousClock.now
                var result = Self.compute(text: text, tool: tool, action: refreshOutput ? action : nil, options: options, wantsTree: wantsTree)
                result.duration = start.duration(to: .now)
                return result
            }
            guard !Task.isCancelled else { return }
            self?.apply(result, generation: current, refreshOutput: refreshOutput)
        }
    }

    private struct Result: Sendable {
        let output: String
        var summary: String?
        let issue: WorkbenchIssue?
        let validation: WorkbenchValidation
        let tree: JSONTreeNode?
        let inputStats: TextStats
        let outputStats: TextStats
        var outputTooLargeForEditor = false
        /// Hesaplama süresi (çıktı bölmesinin alt bilgisinde).
        var duration: Duration = .zero
    }

    nonisolated private static func compute(
        text: String,
        tool: WorkbenchTool,
        action: WorkbenchAction?,
        options: WorkbenchOptions,
        wantsTree: Bool
    ) -> Result {
        let inputStats = TextStats(text)
        // Girdisiz çalışan eylemler (UUID üretme, "şu an") boş girdide de koşar.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || action?.runsOnEmptyInput == true else {
            return Result(output: "", issue: nil, validation: .empty, tree: nil, inputStats: inputStats, outputStats: .empty)
        }
        let validation = tool.validate?(text) ?? .empty
        var output = ""
        var summary: String?
        var issue: WorkbenchIssue?
        do {
            if let action {
                let result = try action.perform(text, options: options)
                output = result.output
                summary = result.summary
            }
        } catch let error as WorkbenchIssue {
            issue = error
        } catch {
            issue = WorkbenchIssue(message: error.localizedDescription)
        }
        var tree: JSONTreeNode?
        if wantsTree, case .valid = validation, let value = try? JSONDocument.parse(text) {
            tree = JSONTreeNode(value: value)
        }
        return Result(output: output, summary: summary, issue: issue, validation: validation, tree: tree,
                      inputStats: inputStats, outputStats: TextStats(output),
                      outputTooLargeForEditor: WorkbenchLimits.isTooLargeForEditor(output, maxBytes: WorkbenchLimits.maxOutputBytes))
    }

    private func apply(_ result: Result, generation: Int, refreshOutput: Bool = true) {
        // Daha yeni bir çalıştırma başladıysa bu sonuç eskidir.
        guard generation == self.generation else { return }
        if refreshOutput {
            output = result.output
            lastRunDuration = result.duration
            outputHiddenFromEditor = result.outputTooLargeForEditor
            if result.outputTooLargeForEditor { isEditingOutput = false; editedOutput = nil }
            actionIssue = result.issue
            outputSummary = result.summary
            outputStats = result.outputStats
        }
        validation = result.validation
        tree = result.tree
        inputStats = result.inputStats
        isRunning = false
        isStale = false
    }
}
