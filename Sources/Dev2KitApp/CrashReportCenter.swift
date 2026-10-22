import Foundation
import Observation
import Dev2KitCore

/// Contact panosundaki "Son çökme raporu" bölümünün durumu. Disk işi
/// (`CrashDiagnostics`, `DiagnosticLog`) arka planda; burada yalnızca sonuç.
///
/// Yalnızca `.app` paketinde etkin (`AppDelegate` başlatır): testlerde ve
/// `swift run` ile çalışırken rapor aranmaz, günlük yazılmaz.
@MainActor
@Observable
final class CrashReportCenter {
    static let shared = CrashReportCenter()

    enum State: Equatable {
        /// Açılış taraması sürüyor.
        case checking
        /// Paketsiz çalıştırma: rapor aranmıyor.
        case inactive
        case ready(CrashReportStatus)
    }

    private(set) var state: State
    /// Ekranda gösterilen ve kopyalanan metin (rapor varsa).
    private(set) var reportText: String?

    /// Testler belirli bir durumla kurar; uygulama `shared` kullanır.
    init(state: State = .inactive, reportText: String? = nil) {
        self.state = state
        self.reportText = reportText
    }

    @ObservationIgnored private var diagnostics: CrashDiagnostics?
    @ObservationIgnored private let current = SessionRecord.current()
    @ObservationIgnored private let log = DiagnosticLog.shared
    @ObservationIgnored private let worker = DispatchQueue(label: "dev2kit.crash-report", qos: .utility)

    /// Açılışta bir kez: önceki oturumu değerlendirir, bu oturumu kaydeder.
    func start() {
        guard diagnostics == nil else { return }
        let diagnostics = CrashDiagnostics.live(log: log)
        self.diagnostics = diagnostics
        state = .checking
        log.activate(directory: diagnostics.directory)
        log.record(DiagnosticEvent(kind: .sessionStarted))
        let current = current
        run { diagnostics.launch(current: current) }
    }

    /// Pano açılınca: geç yazılan macOS raporu varsa kaydı yükseltir.
    func refresh() {
        guard let diagnostics else { return }
        run { diagnostics.refresh() }
    }

    func clear() {
        guard let diagnostics else { return }
        run { diagnostics.clear() }
    }

    /// Temiz kapanış (`applicationWillTerminate`): kısa ve eşzamanlı.
    func endSession() {
        guard let diagnostics else { return }
        log.record(DiagnosticEvent(kind: .sessionEnded))
        log.flush()
        diagnostics.endSession(pid: current.pid)
    }

    private func run(_ work: @escaping @Sendable () -> CrashReportStatus) {
        let log = log
        let current = current
        worker.async {
            let status = work()
            let text = status.latest.map { CrashReportText.make($0, events: log.recentEvents(), current: current) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.state = .ready(status)
                    self.reportText = text
                }
            }
        }
    }
}
