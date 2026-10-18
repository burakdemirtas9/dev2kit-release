import Foundation
import Observation
import Dev2KitCore

/// Diff Checker'da bir sekme: iki girdi, dil ve seçenekler.
struct DiffDocument: Identifiable, Equatable {
    let id = UUID()
    let number: Int
    var left = ""
    var right = ""
    var language: DiffChecker.Language = .json
    var options = DiffChecker.Options()
    var resultMode: DiffCheckerState.ResultMode = .changes

    var hasContent: Bool { !left.isEmpty || !right.isEmpty }
}

/// Diff Checker'ın durumu (docs/V2.md "Diff"). Araç ekranının
/// (`WorkbenchState`) kuralları burada da geçerli:
/// - Girdiler yalnızca bellekte, sekme başına; diske/geçmişe yazılmaz.
/// - Sonuç yalnızca açık sekme için tutulur; sekme değişince bırakılır.
/// - Karşılaştırma ana thread dışında; eski çalıştırmanın sonucu yenisini
///   ezmez (nesil sayacı).
///
/// Ölçüm (M4, release, 2026-10-18): normalize + karşılaştırma ~250 ms/MB
/// (çoğu iki tarafın biçimlendirilmesi). Taraf başına 1 MB'a kadar otomatik.
@Observable
@MainActor
final class DiffCheckerState {
    static let autoRunLimit = 1_048_576
    static let debounce: Duration = .milliseconds(400)

    enum ResultMode: String, CaseIterable, Identifiable {
        case changes, lines
        var id: String { rawValue }
        var title: String { self == .changes ? "Changes" : "Lines" }
    }

    private(set) var documents: [DiffDocument]
    private(set) var selectedID: UUID

    private(set) var result: DiffChecker.Result?
    private(set) var isRunning = false
    private(set) var isStale = false
    /// "Önceki/sonraki fark" gezintisinde bulunulan blok.
    private(set) var currentChange: Int?
    /// Sonuca yer açmak için girdiler gizlenebilir.
    var inputsHidden = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?

    init() {
        let first = DiffDocument(number: 1)
        documents = [first]
        selectedID = first.id
    }

    var document: DiffDocument {
        documents.first { $0.id == selectedID } ?? documents[0]
    }

    var isLarge: Bool {
        document.left.utf8.count > Self.autoRunLimit || document.right.utf8.count > Self.autoRunLimit
    }

    /// JSON'da anlamsal liste var mı (iki taraf da geçerli JSON).
    var showsChanges: Bool {
        document.language == .json && result?.jsonChanges != nil && document.resultMode == .changes
    }

    // MARK: - Girdiler ve seçenekler

    var left: String {
        get { document.left }
        set { mutate { $0.left = newValue }; inputChanged() }
    }

    var right: String {
        get { document.right }
        set { mutate { $0.right = newValue }; inputChanged() }
    }

    func select(language: DiffChecker.Language) {
        mutate { $0.language = language }
        schedule(debounced: false)
    }

    func update(options: DiffChecker.Options) {
        mutate { $0.options = options }
        schedule(debounced: false)
    }

    func select(resultMode: ResultMode) {
        mutate { $0.resultMode = resultMode }
    }

    func swapSides() {
        let doc = document
        mutate { $0.left = doc.right; $0.right = doc.left }
        schedule(debounced: false, force: true)
    }

    func runNow() {
        schedule(debounced: false, force: true)
    }

    // MARK: - Fark gezintisi

    /// Gidilecek satırın kimliği (sonuç listesi kaydırır).
    func moveToChange(forward: Bool) -> Int? {
        guard let starts = result?.changeStarts, !starts.isEmpty else { return nil }
        let next: Int
        if let current = currentChange {
            next = forward ? (current + 1) % starts.count : (current - 1 + starts.count) % starts.count
        } else {
            next = forward ? 0 : starts.count - 1
        }
        currentChange = next
        return starts[next]
    }

    // MARK: - Sekmeler

    func title(of doc: DiffDocument) -> String { "Diff \(doc.number)" }

    func newDocument() {
        let used = Set(documents.map(\.number))
        let doc = DiffDocument(number: (1...).first { !used.contains($0) } ?? 1)
        documents.append(doc)
        selectedID = doc.id
        documentChanged()
    }

    func select(documentID: UUID) {
        guard documentID != selectedID, documents.contains(where: { $0.id == documentID }) else { return }
        selectedID = documentID
        documentChanged()
    }

    func closeDocument(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = id == selectedID
        documents.remove(at: index)
        if documents.isEmpty { documents = [DiffDocument(number: 1)] }
        if wasSelected || !documents.contains(where: { $0.id == selectedID }) {
            selectedID = documents[min(index, documents.count - 1)].id
            documentChanged()
        }
    }

    // MARK: - İç işler

    private func mutate(_ change: (inout DiffDocument) -> Void) {
        guard let index = documents.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&documents[index])
    }

    private func inputChanged() {
        if isLarge {
            runTask?.cancel()
            isStale = true
        } else {
            schedule(debounced: true)
        }
    }

    private func documentChanged() {
        result = nil
        currentChange = nil
        schedule(debounced: false, force: true)
    }

    private func schedule(debounced: Bool, force: Bool = false) {
        runTask?.cancel()
        generation += 1
        let current = generation
        guard force || !isLarge else { isStale = true; return }
        let doc = document
        guard doc.hasContent else {
            result = nil
            isRunning = false
            isStale = false
            return
        }
        isRunning = true
        runTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: Self.debounce)
                if Task.isCancelled { return }
            }
            // Büyük yığın: derin girdide yığın taşmasın (BackgroundWork).
            let result = await BackgroundWork.run {
                DiffChecker.compare(doc.left, doc.right, language: doc.language, options: doc.options)
            }
            guard !Task.isCancelled, let self, current == self.generation else { return }
            self.result = result
            self.currentChange = nil
            self.isRunning = false
            self.isStale = false
        }
    }
}
