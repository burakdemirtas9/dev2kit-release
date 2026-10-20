import Foundation
import Observation
import Dev2KitCore

/// Diff Checker'ın belgesi: iki girdi, dil ve seçenekler. Sekme yok
/// (kullanıcı kararı, 2026-10-19: Workbench'te sekmeler yalnızca JSON'da).
struct DiffDocument: Identifiable, Equatable {
    let id = UUID()
    var left = ""
    var right = ""
    var language: DiffChecker.Language = .json
    var options = DiffChecker.Options()
    var resultMode: DiffCheckerState.ResultMode = .changes
    /// Taraf editörde gösterilemeyecek kadar büyük ya da uzun satırlı
    /// (`WorkbenchLimits`): saklanır ve karşılaştırılır, editör yerine açıklama.
    var leftTooLargeForEditor = false
    var rightTooLargeForEditor = false

    var hasContent: Bool { !left.isEmpty || !right.isEmpty }
}

/// Diff Checker'ın durumu (docs/V2.md "Diff"). Araç ekranının
/// (`WorkbenchState`) kuralları burada da geçerli:
/// - Girdiler yalnızca bellekte; diske/geçmişe yazılmaz.
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
        var title: String { self == .changes ? L10n.t("diff.mode.changes") : L10n.t("diff.mode.lines") }
    }

    private(set) var document = DiffDocument()

    private(set) var result: DiffChecker.Result?
    private(set) var isRunning = false
    private(set) var isStale = false
    /// "Önceki/sonraki fark" gezintisinde bulunulan blok.
    private(set) var currentChange: Int?
    /// Sonuca yer açmak için girdiler gizlenebilir.
    var inputsHidden = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?

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
        set {
            let hidden = WorkbenchLimits.isTooLargeForEditor(newValue)
            mutate { $0.left = newValue; $0.leftTooLargeForEditor = hidden }
            inputChanged()
        }
    }

    var right: String {
        get { document.right }
        set {
            let hidden = WorkbenchLimits.isTooLargeForEditor(newValue)
            mutate { $0.right = newValue; $0.rightTooLargeForEditor = hidden }
            inputChanged()
        }
    }

    /// Sınır nedeniyle yapılmayan değişikliğin açıklaması (kırmızı); bir süre
    /// sonra kalkar. `WorkbenchState.limitNotice` ile aynı davranış.
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
        mutate {
            $0.left = doc.right
            $0.right = doc.left
            $0.leftTooLargeForEditor = doc.rightTooLargeForEditor
            $0.rightTooLargeForEditor = doc.leftTooLargeForEditor
        }
        schedule(debounced: false, force: true)
    }

    func runNow() {
        schedule(debounced: false, force: true)
    }

    /// Arayüz dili değişti: uyarılar yeni dilde yeniden üretilsin. Büyük
    /// girdi kendiliğinden çalışmaz, ona dokunulmaz.
    func languageChanged() {
        guard !isLarge, result != nil else { return }
        schedule(debounced: false)
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

    /// Araç seçilince sol girdi odak alır (`WorkbenchState.inputFocusRequest`).
    private(set) var focusRequest = 0

    func requestFocus() { focusRequest += 1 }

    // MARK: - İç işler

    private func mutate(_ change: (inout DiffDocument) -> Void) {
        change(&document)
    }

    private func inputChanged() {
        if isLarge {
            runTask?.cancel()
            isStale = true
        } else {
            schedule(debounced: true)
        }
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
