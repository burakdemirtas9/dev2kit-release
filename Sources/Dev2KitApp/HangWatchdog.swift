import AppKit
import Darwin
import Dev2KitCore

/// Donma bekçisi (2026-10-31): ayrı bir iş parçacığından ana iş parçacığını
/// saniyede bir yoklar. Karar `HangWatchdogPolicy`'de (Core, testli); burada
/// yalnızca ölçüm ve uygulama.
///
/// Yanlış alarm olmasın diye:
/// - Süre uyku saymayan saatle (`SuspendingClock`): Mac uyurken geçen süre yok.
/// - "Yanıtsızlık", ana iş parçacığına bırakılan yoklamanın İŞLENMEDEN
///   beklediği süredir. macOS arka plandaki uygulamayı yavaşlatıp bekçinin
///   kendi uyanışını geciktirse bile (App Nap) bu süre şişmez.
/// - Uyku, ekran uykusu, ekran kilidi ve oturum devrinde susar; dönüşte 30 sn
///   pay (bildirimler sağlıklı ana iş parçacığında gelir; o anlar zaten yanlış
///   alarmın olabileceği anlar).
///
/// Kaçak durumda (donma + bellek sınırı) kaydı diske indirir ve SIGABRT'yi
/// ANA iş parçacığına gönderir: macOS'un çökme raporu donan iş parçacığının
/// yığınını "çöken iş parçacığı" olarak yazar, pano onu gösterir.
///
/// Yalnızca `.app` paketinde başlatılır (`AppDelegate`); testlerde ve
/// `swift run`'da çalışmaz.
final class HangWatchdog: @unchecked Sendable {
    struct Configuration: @unchecked Sendable {
        var thresholds = HangWatchdogPolicy.Thresholds()
        /// Yoklama aralığı (saniye).
        var interval: TimeInterval = 1
        var memoryMB: () -> Int? = ProcessMemory.footprintMB
        var log: DiagnosticLog = .shared
        /// "Bekçi kapattı" işaretinin yazıldığı dizin (tanılama dizini).
        var directory: URL
        /// Kaçak durumda son adım. Varsayılan: ana iş parçacığına SIGABRT.
        var terminate: (pthread_t?) -> Void = HangWatchdog.abortMainThread
    }

    static let shared = HangWatchdog(configuration: Configuration(directory: CrashDiagnostics.defaultDirectory()))

    private let configuration: Configuration
    private let clock = SuspendingClock()
    private let origin: SuspendingClock.Instant
    private let lock = NSLock()

    // `lock` ile korunanlar.
    private var running = false
    /// Ana iş parçacığına bırakılmış, henüz işlenmemiş yoklamanın bırakıldığı an.
    private var pendingSince: Double?
    private var context = DiagnosticContext()
    private var asleep = false
    private var screensAsleep = false
    private var screenLocked = false
    private var sessionInactive = false

    private var mainThread: pthread_t?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @MainActor private var contextProvider: (() -> DiagnosticContext)?

    init(configuration: Configuration) {
        self.configuration = configuration
        origin = clock.now
    }

    /// Ana iş parçacığından bir kez. `context`: her yoklamada ana iş
    /// parçacığında ucuz bir anlık durum (ekran, kaba boyutlar).
    @MainActor
    func start(context: @escaping @MainActor () -> DiagnosticContext) {
        let alreadyRunning = withLock { () -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else { return }
        contextProvider = context
        mainThread = pthread_self()
        observeSystemState()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "dev2kit.hang-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Testler için: döngü bir sonraki turda biter.
    func stop() {
        withLock { running = false }
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    // MARK: - Bekçi iş parçacığı

    private func run() {
        var policy = HangWatchdogPolicy(thresholds: configuration.thresholds, startedAt: seconds())
        while withLock({ running }) {
            Thread.sleep(forTimeInterval: configuration.interval)
            postHeartbeatIfNeeded()
            let now = seconds()
            let state = withLock { (pendingSince, suppressed, context) }
            let memory = configuration.memoryMB() ?? 0
            let actions = policy.evaluate(now: now, lastHeartbeat: state.0 ?? now, memoryMB: memory, suppressed: state.1)
            for action in actions {
                handle(action, context: state.2, memory: memory)
            }
        }
    }

    private var suppressed: Bool { asleep || screensAsleep || screenLocked || sessionInactive }

    private func postHeartbeatIfNeeded() {
        let posted = withLock { () -> Bool in
            guard pendingSince == nil else { return false }
            pendingSince = seconds()
            return true
        }
        guard posted else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let context = self.contextProvider?() ?? DiagnosticContext()
                self.withLock {
                    self.pendingSince = nil
                    self.context = context
                }
            }
        }
    }

    private func handle(_ action: HangWatchdogPolicy.Action, context: DiagnosticContext, memory: Int) {
        var context = context
        context.memoryMB = ProcessMemory.rounded(memory)
        switch action {
        case .recordHang(let stall):
            context.stallSeconds = stall
            configuration.log.record(DiagnosticEvent(kind: .mainThreadHang, context: context))
        case .recordRecovered(let stall):
            configuration.log.record(DiagnosticEvent(kind: .mainThreadRecovered,
                                                     context: DiagnosticContext(memoryMB: context.memoryMB, stallSeconds: stall)))
        case .recordHighMemory:
            configuration.log.record(DiagnosticEvent(kind: .memoryHigh, context: context))
        case .terminate(let stall):
            context.stallSeconds = stall
            configuration.log.record(DiagnosticEvent(kind: .watchdogTerminated, context: context))
            configuration.log.flush()
            WatchdogTermination.write(
                WatchdogTermination(time: Date(), stallSeconds: stall, memoryMB: ProcessMemory.rounded(memory)),
                in: configuration.directory
            )
            withLock { running = false }
            configuration.terminate(mainThread)
        }
    }

    /// SIGABRT ana iş parçacığına: varsayılan işlemle süreç sonlanır ve macOS
    /// raporunda ana iş parçacığı "çöken" olur. Sinyal işleyicisi yok (bkz.
    /// `CrashDiagnostics`). Sinyal ulaşmazsa birkaç saniye sonra `abort()`.
    static func abortMainThread(_ thread: pthread_t?) {
        if let thread { pthread_kill(thread, SIGABRT) }
        Thread.sleep(forTimeInterval: 3)
        abort()
    }

    // MARK: - Uyku, kilit, oturum

    @MainActor
    private func observeSystemState() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        // Ekran kilidi için AppKit sabiti yok; sistemin dağıtık bildirimi.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping (HangWatchdog) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.withLock { change(self) }
        }
        observers.append((center, token))
    }

    // MARK: - Yardımcılar

    private func seconds() -> Double {
        let elapsed = origin.duration(to: clock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
