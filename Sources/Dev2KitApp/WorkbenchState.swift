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
        var title: String { self == .text ? "Text" : "Tree" }
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
    private(set) var actionIssue: WorkbenchIssue?
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
            mutateDocument { $0.input = newValue }
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

    func select(toolID: String) {
        guard toolID != selectedToolID,
              WorkbenchCatalog.tool(id: toolID) != nil || toolID == WorkbenchCatalog.diffCheckerID else { return }
        selectedToolID = toolID
        UserDefaults.standard.set(toolID, forKey: "workbenchTool")
        guard !showsDiffChecker else { return }
        ensureDocument()
        documentChanged()
    }

    func select(documentID: UUID) {
        guard documentID != document.id, documents.contains(where: { $0.id == documentID }) else { return }
        selectedDocumentByTool[tool.id] = documentID
        documentChanged()
    }

    func newDocument() {
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
        mutateDocument { $0.input = newInput }
        if clearedInput != nil { dismissUndo() }
        inputStats = TextStats(bytes: newInput.utf8.count, lines: inputStats.lines, characters: inputStats.characters)
        schedule(debounced: true, refreshOutput: false)
    }

    func useOutputAsInput() {
        let text = displayedOutput
        guard !text.isEmpty else { return }
        input = text
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
        output = ""
        editedOutput = nil
        isEditingOutput = false
        tree = nil
        actionIssue = nil
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
            let result = await Task.detached(priority: .userInitiated) {
                Self.compute(text: text, tool: tool, action: refreshOutput ? action : nil, options: options, wantsTree: wantsTree)
            }.value
            guard !Task.isCancelled else { return }
            self?.apply(result, generation: current, refreshOutput: refreshOutput)
        }
    }

    private struct Result: Sendable {
        let output: String
        let issue: WorkbenchIssue?
        let validation: WorkbenchValidation
        let tree: JSONTreeNode?
        let inputStats: TextStats
        let outputStats: TextStats
    }

    nonisolated private static func compute(
        text: String,
        tool: WorkbenchTool,
        action: WorkbenchAction?,
        options: WorkbenchOptions,
        wantsTree: Bool
    ) -> Result {
        let inputStats = TextStats(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(output: "", issue: nil, validation: .empty, tree: nil, inputStats: inputStats, outputStats: .empty)
        }
        let validation = tool.validate?(text) ?? .empty
        var output = ""
        var issue: WorkbenchIssue?
        do {
            if let action { output = try action.run(text, options) }
        } catch let error as WorkbenchIssue {
            issue = error
        } catch {
            issue = WorkbenchIssue(message: error.localizedDescription)
        }
        var tree: JSONTreeNode?
        if wantsTree, case .valid = validation, let value = try? JSONDocument.parse(text) {
            tree = JSONTreeNode(value: value)
        }
        return Result(output: output, issue: issue, validation: validation, tree: tree,
                      inputStats: inputStats, outputStats: TextStats(output))
    }

    private func apply(_ result: Result, generation: Int, refreshOutput: Bool = true) {
        // Daha yeni bir çalıştırma başladıysa bu sonuç eskidir.
        guard generation == self.generation else { return }
        if refreshOutput {
            output = result.output
            actionIssue = result.issue
            outputStats = result.outputStats
        }
        validation = result.validation
        tree = result.tree
        inputStats = result.inputStats
        isRunning = false
        isStale = false
    }
}
