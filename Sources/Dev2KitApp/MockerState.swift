import Foundation
import Observation
import Dev2KitCore

/// Mocker modunun durumu (2026-11-07). Uygulama düzeyinde tutulur: kullanıcı
/// API Client'a ya da Workbench'e geçince sunucu çalışmaya devam eder.
///
/// İki tanım kümesi var:
/// - `endpoints`: ekranda düzenlenen taslak; her değişiklikte diske yazılır.
/// - Çalışan tanımlar (`applied`): sunucunun kullandığı anlık görüntü.
///   Kullanıcı "Değişiklikleri Uygula"ya basana kadar değişmez.
@Observable
@MainActor
final class MockerState {
    enum Status: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    enum Pane: String, CaseIterable, Identifiable {
        case definitions
        case requests
        var id: String { rawValue }
    }

    var endpoints: [MockEndpoint] {
        didSet { endpointsChanged() }
    }
    var selectedEndpointID: UUID?
    var pane: Pane = .definitions
    private(set) var status: Status = .stopped
    /// Sunucudaki taslak hali (uygulandığı andaki `endpoints`).
    private(set) var applied: [MockEndpoint]?
    /// Çalışırken taslak çalışan tanımlardan farklı mı.
    private(set) var hasUnappliedChanges = false
    private(set) var issues: [MockIssue] = []
    /// En yeni başta; en çok `MockerLimits.logCapacity`. Yalnızca bellekte.
    private(set) var log: [MockLogEvent] = []
    var selectedLogID: UUID?
    /// Mocker kendiliğinden durduysa nedeni (uyku, kilit, boşta kalma); Başlat'ta kalkar.
    private(set) var autoStopNotice: String?

    /// Kendiliğinden durma nedeni.
    enum AutoStopReason: Equatable {
        case idle
        case sleep
        case locked
    }

    /// Açılışta dosya okunamadıysa (kenara alındı) kullanıcıya bir kez söylenir.
    var loadNotice: String?
    private(set) var saveError: String?

    @ObservationIgnored private let store: MockerStore
    @ObservationIgnored private let ports: [UInt16]
    @ObservationIgnored private var server: MockServer?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private let idleStopSeconds: Double
    @ObservationIgnored private var idleWork: DispatchWorkItem?
    @ObservationIgnored private var presence: SystemPresenceObserver?

    init(root: URL = AppPaths.supportDirectory, ports: [UInt16] = MockerLimits.ports,
         idleStopSeconds: Double = MockerLimits.idleStopSeconds) {
        store = MockerStore(root: root)
        self.ports = ports
        self.idleStopSeconds = idleStopSeconds
        switch store.load() {
        case .loaded(let document):
            endpoints = document.endpoints
        case .missing:
            endpoints = []
        case .corrupt(let name):
            endpoints = []
            loadNotice = L10n.t("mocker.loadCorrupt", name)
        }
        selectedEndpointID = endpoints.first?.id
        issues = MockValidator.issues(for: endpoints)
    }

    // MARK: Durum

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var port: UInt16? {
        if case .running(let port) = status { return port }
        return nil
    }

    /// Mod seçicideki yayın simgesi (kullanıcı kararı, 2026-11-07: 3. seçenek).
    var modeIndicator: MockerModeIndicator {
        switch status {
        case .running(let port):
            return hasUnappliedChanges ? .unapplied(port: port) : .running(port: port)
        case .failed(let message):
            return .failed(message)
        case .stopped, .starting:
            return .hidden
        }
    }

    /// Ekranda gösterilen adres.
    var address: String? { port.map { "http://localhost:\($0)" } }

    var selectedEndpoint: MockEndpoint? {
        endpoints.first { $0.id == selectedEndpointID }
    }

    func issues(for endpointID: UUID) -> [MockIssue] {
        issues.filter { $0.endpointID == endpointID }
    }

    // MARK: Sunucu

    func start() async {
        guard !isRunning, status != .starting else { return }
        status = .starting
        autoStopNotice = nil
        let server = MockServer { [weak self] event in
            Task { @MainActor in self?.record(event) }
        }
        let snapshot = endpoints
        do {
            let port = try await server.start(endpoints: Self.servable(snapshot), ports: ports)
            self.server = server
            applied = snapshot
            status = .running(port: port)
            refreshUnapplied()
            watchForAutoStop()
        } catch MockServer.StartError.portsInUse(let ports) {
            status = .failed(Self.portsInUseMessage(ports))
        } catch {
            status = .failed(L10n.t("mocker.startFailed", error.localizedDescription))
        }
    }

    func stop() async {
        guard let server else {
            if case .failed = status { status = .stopped }
            return
        }
        self.server = nil
        idleWork?.cancel()
        idleWork = nil
        presence?.cancel()
        presence = nil
        await server.stop()
        applied = nil
        status = .stopped
        refreshUnapplied()
    }

    // MARK: Kendiliğinden durma (kaynak koruma)

    /// Çalışırken: uyku ve ekran kilidi dinlenir, boşta kalma sayacı kurulur.
    /// Boştayken tek bir zamanlayıcı; her istekte yeniden kurulur.
    private func watchForAutoStop() {
        presence?.cancel()
        presence = SystemPresenceObserver { [weak self] event in
            let reason: AutoStopReason
            switch event {
            case .willSleep: reason = .sleep
            case .screenLocked, .sessionResigned: reason = .locked
            default: return
            }
            Task { @MainActor in await self?.autoStop(reason) }
        }
        rescheduleIdleStop()
    }

    private func rescheduleIdleStop() {
        idleWork?.cancel()
        guard isRunning else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.autoStop(.idle) }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleStopSeconds, execute: work)
    }

    func autoStop(_ reason: AutoStopReason) async {
        guard isRunning else { return }
        await stop()
        autoStopNotice = Self.autoStopMessage(reason, idleMinutes: Int((idleStopSeconds / 60).rounded()))
    }

    static func autoStopMessage(_ reason: AutoStopReason, idleMinutes: Int) -> String {
        switch reason {
        case .idle: return L10n.t("mocker.autoStop.idle", L10n.number(idleMinutes))
        case .sleep: return L10n.t("mocker.autoStop.sleep")
        case .locked: return L10n.t("mocker.autoStop.locked")
        }
    }

    func dismissAutoStopNotice() {
        autoStopNotice = nil
    }

    /// Taslağı çalışan sunucuya verir. Soket kapanmaz: port aynı kalır.
    func applyChanges() {
        guard let server, isRunning else { return }
        let snapshot = endpoints
        server.update(endpoints: Self.servable(snapshot))
        applied = snapshot
        refreshUnapplied()
        rescheduleIdleStop()
    }

    /// Yolu hatalı endpoint'ler sunulmaz (uyarısı ekranda).
    static func servable(_ endpoints: [MockEndpoint]) -> [MockEndpoint] {
        endpoints.filter { MockValidator.pathError($0.path) == nil }
    }

    /// "8098, 8099 ve 8100 portları kullanımda…" (kullanıcının metni, 2026-11-07).
    static func portsInUseMessage(_ ports: [UInt16]) -> String {
        let names = ports.map(String.init)
        let list: String
        if names.count > 1 {
            list = names.dropLast().joined(separator: ", ") + L10n.t("mocker.and") + names[names.count - 1]
        } else {
            list = names.first ?? ""
        }
        return L10n.t("mocker.portsInUse", list)
    }

    private func record(_ event: MockLogEvent) {
        rescheduleIdleStop()
        log.insert(event, at: 0)
        if log.count > MockerLimits.logCapacity { log.removeLast(log.count - MockerLimits.logCapacity) }
    }

    func clearLog() {
        log = []
        selectedLogID = nil
    }

    // MARK: Düzenleme

    var canAddEndpoint: Bool { endpoints.count < MockerLimits.maxEndpoints }

    @discardableResult
    func addEndpoint() -> UUID? {
        guard canAddEndpoint else { return nil }
        let endpoint = MockEndpoint(method: .any, path: Self.newPath(existing: endpoints))
        endpoints.append(endpoint)
        selectedEndpointID = endpoint.id
        pane = .definitions
        return endpoint.id
    }

    /// "/new", "/new-2"…: yeni endpoint var olanla çakışmasın.
    static func newPath(existing: [MockEndpoint]) -> String {
        let paths = Set(existing.map(\.path))
        var candidate = "/new"
        var number = 2
        while paths.contains(candidate) {
            candidate = "/new-\(number)"
            number += 1
        }
        return candidate
    }

    func duplicateEndpoint(_ id: UUID) {
        guard canAddEndpoint, let index = endpoints.firstIndex(where: { $0.id == id }) else { return }
        var copy = endpoints[index]
        copy.id = UUID()
        copy.scenarios = copy.scenarios.map { scenario in
            var scenario = scenario
            scenario.id = UUID()
            scenario.conditions = scenario.conditions.map { var c = $0; c.id = UUID(); return c }
            return scenario
        }
        endpoints.insert(copy, at: index + 1)
        selectedEndpointID = copy.id
    }

    func deleteEndpoint(_ id: UUID) {
        guard let index = endpoints.firstIndex(where: { $0.id == id }) else { return }
        endpoints.remove(at: index)
        if selectedEndpointID == id {
            selectedEndpointID = endpoints.indices.contains(index) ? endpoints[index].id : endpoints.last?.id
        }
    }

    func moveEndpoint(_ id: UUID, by offset: Int) {
        guard let index = endpoints.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard endpoints.indices.contains(target) else { return }
        endpoints.swapAt(index, target)
    }

    func select(endpointID: UUID?) {
        selectedEndpointID = endpointID
        pane = .definitions
    }

    // MARK: Kalıcılık ve türetilmiş durum

    private func endpointsChanged() {
        issues = MockValidator.issues(for: endpoints)
        refreshUnapplied()
        saveSoon()
    }

    private func refreshUnapplied() {
        // Tanımdaki her değişiklik, eşleşmeyi etkilemeyen örnek request body
        // dahil, "Uygula" ister (kullanıcı isteği, 2026-11-07: tutarlı olsun).
        let changed = isRunning && applied != endpoints
        if hasUnappliedChanges != changed { hasUnappliedChanges = changed }
    }

    /// Yazma her tuşta değil, 400 ms sonra (UI-KURALLARI §4); disk işi seri kuyrukta.
    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let document = MockerDocument(endpoints: endpoints)
        let store = store
        PersistenceQueue.shared.async { [weak self] in
            let failure: String?
            do {
                try store.save(document)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.saveError = failure }
            }
        }
    }

    /// Kapanışta: bekleyen kayıt hemen kuyruğa, kuyruk boşalana kadar beklenir.
    func flushPendingSave() {
        if saveWork != nil { saveNow() }
        PersistenceQueue.shared.sync {}
    }
}
