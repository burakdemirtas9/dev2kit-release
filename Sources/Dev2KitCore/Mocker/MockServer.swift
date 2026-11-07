import Foundation
import Network

/// Gelen bir isteğin kaydı (arayüzdeki "Gelen istekler"; yalnızca bellekte).
public struct MockLogEvent: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let method: String
    public let target: String
    public let headers: [MockHeader]
    /// Gövdenin başı (en çok `MockerLimits.logBodyPreviewBytes`).
    public let bodyPreview: String
    public let bodyBytes: Int
    /// `nil`: istek okunamadı (bozuk, sınır aşımı).
    public let outcome: MockRoute.Outcome?
    public let endpointID: UUID?
    public let status: Int
    /// Gelişten yanıtın gönderilmesine kadar (gecikme dahil).
    public let milliseconds: Int
}

/// Yerel mock HTTP sunucusu (Mocker, 2026-11-07).
///
/// - **Yalnızca bu Mac:** geri döngü arayüzüne bağlı; `localhost`, `127.0.0.1`
///   ve `::1` ile erişilir, ağdan erişilemez (ölçüldü, `bind(port:)`).
/// - **Başkasının portunu çalmaz:** adres yeniden kullanımı kapalı. Port başka
///   bir programda açıksa bağlanma başarısız olur ve sıradaki port denenir
///   (`MockerLimits.ports`).
/// - **Boşta iş yok:** dinleyici ve bağlantılar olay geldiğinde uyanır;
///   zamanlayıcı yalnızca açık bağlantının boşta kalma süresi için.
/// - **Tanım değişimi** (`update`): soket kapatılmadan çalışan tanımlar
///   değiştirilir, port korunur; o anda işlenen istek eski tanımla biter.
///
/// Durum tek seri kuyrukta (`queue`); dışarıdan çağrılar kuyruğa geçer.
/// Eşleştirme 16 MB yığınlı iş parçacığında: iç içe JSON gövdesi okunurken
/// yığın taşmasın (UI-KURALLARI §4, `BackgroundWork`).
public final class MockServer: @unchecked Sendable {
    public enum StartError: Error, Equatable, Sendable {
        /// Denenen portların hepsi dolu.
        case portsInUse([UInt16])
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.dev2kit.mocker", qos: .userInitiated)
    private let onEvent: @Sendable (MockLogEvent) -> Void
    // Aşağıdakiler yalnızca `queue` üzerinde.
    private var listeners: [NWListener] = []
    private var endpoints: [MockEndpoint] = []
    private var connections: [ObjectIdentifier: MockConnection] = [:]

    public init(onEvent: @escaping @Sendable (MockLogEvent) -> Void = { _ in }) {
        self.onEvent = onEvent
    }

    /// Portları sırayla dener; dinlenen portu döner.
    public func start(endpoints: [MockEndpoint], ports: [UInt16] = MockerLimits.ports) async throws -> UInt16 {
        await stop()
        for port in ports {
            switch await bind(port: port) {
            case .failure(let error):
                if Self.isInUse(error) { continue }
                throw StartError.failed(error.localizedDescription)
            case .success(let listener):
                await onQueue {
                    self.listeners = [listener]
                    self.endpoints = endpoints
                }
                return port
            }
        }
        throw StartError.portsInUse(ports)
    }

    /// Çalışan tanımları değiştirir (soket açık kalır, port korunur).
    public func update(endpoints: [MockEndpoint]) {
        queue.async { self.endpoints = endpoints }
    }

    /// Dinleyicileri ve açık bağlantıları kapatır.
    /// Dinleyici gerçekten kapanana kadar bekler: iptal eşzamansız, beklenmezse
    /// hemen ardından gelen Başlat aynı portu "kullanımda" bulup sıradakine
    /// geçiyordu (aralıklı test hatası, 2026-11-07).
    public func stop() async {
        let closing = ListenerBox()
        await onQueue {
            closing.listeners = self.listeners
            self.listeners = []
            self.connections.values.forEach { $0.close() }
            self.connections = [:]
        }
        for listener in closing.listeners {
            await cancelAndWait(listener)
        }
    }

    private func cancelAndWait(_ listener: NWListener) async {
        let queue = queue
        await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            queue.async {
                if case .cancelled = listener.state {
                    if resumed.claim() { continuation.resume() }
                    return
                }
                listener.stateUpdateHandler = { state in
                    if case .cancelled = state, resumed.claim() { continuation.resume() }
                }
                listener.cancel()
                // Güvenlik: durum hiç gelmezse takılı kalınmaz.
                queue.asyncAfter(deadline: .now() + 1) {
                    if resumed.claim() { continuation.resume() }
                }
            }
        }
    }

    private func onQueue(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                work()
                continuation.resume()
            }
        }
    }

    /// Port kullanılamaz: dolu (ya da izin yok); sıradaki denenir.
    static func isInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE || code == .EACCES }
        return false
    }

    /// Tek dinleyici: tüm adresler, ama yalnızca geri döngü arayüzü (lo0).
    ///
    /// Ölçüldü (2026-11-07): `127.0.0.1` ve `::1` ile erişilir, Mac'in ağ
    /// adresinden bağlantı reddedilir; port başka bir programda (127.0.0.1,
    /// ::1 ya da tüm adreslerde) açıksa bağlanma "kullanımda" hatası verir.
    /// İki ayrı dinleyici (127.0.0.1 + ::1) aynı portta kurulamıyor: ikincisi
    /// her zaman "kullanımda" alıyordu.
    private func bind(port: UInt16) async -> Result<NWListener, NWError> {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return .failure(.posix(.EINVAL)) }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        // Yeniden kullanım kapalı: başka bir programın dinlediği porta "ortak" bağlanılmaz.
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpointPort)
        } catch let error as NWError {
            return .failure(error)
        } catch {
            return .failure(.posix(.EINVAL))
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: .success(listener)) }
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    if resumed.claim() { continuation.resume(returning: .failure(error)) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    // MARK: Bağlantılar (kuyrukta)

    private func accept(_ connection: NWConnection) {
        guard connections.count < MockerLimits.maxConnections else {
            connection.cancel()
            return
        }
        let handler = MockConnection(connection: connection, server: self, queue: queue)
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }

    fileprivate func remove(_ handler: MockConnection) {
        connections[ObjectIdentifier(handler)] = nil
    }

    /// İsteği o anki tanımlarla eşleştirir (büyük yığınlı iş parçacığında),
    /// sonucu kuyrukta verir.
    fileprivate func route(_ request: MockIncomingRequest, completion: @escaping @Sendable (MockRoute) -> Void) {
        let snapshot = endpoints
        let queue = queue
        let thread = Thread {
            let route = MockRouter.route(request, endpoints: snapshot)
            queue.async { completion(route) }
        }
        thread.stackSize = BackgroundWork.stackSize
        thread.qualityOfService = .userInitiated
        thread.name = "dev2kit.mocker-route"
        thread.start()
    }

    fileprivate func report(_ request: MockIncomingRequest?, route: MockRoute?, status: Int, started: ContinuousClock.Instant) {
        let preview = request.map { String(decoding: $0.body.prefix(MockerLimits.logBodyPreviewBytes), as: UTF8.self) } ?? ""
        let elapsed = started.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        onEvent(MockLogEvent(
            id: UUID(), date: Date(), method: request?.method ?? "?", target: request?.target ?? "?",
            headers: request?.headers ?? [], bodyPreview: preview, bodyBytes: request?.body.count ?? 0,
            outcome: route?.outcome, endpointID: route?.endpointID, status: status, milliseconds: milliseconds))
    }
}

/// Kuyruktan dışarı dinleyici listesi taşımak için (yalnızca `stop` kullanır).
private final class ListenerBox: @unchecked Sendable {
    var listeners: [NWListener] = []
}

/// `withCheckedContinuation` tek sefer devam etsin (durum işleyicisi birden çok kez çağrılır).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Tek bağlantı: okur, sırayla yanıtlar (keep-alive), boşta kalınca kapanır.
/// Tüm durum sunucunun kuyruğunda.
private final class MockConnection: @unchecked Sendable {
    private let connection: NWConnection
    private weak var server: MockServer?
    private let queue: DispatchQueue
    private var reader = MockHTTPReader()
    private var busy = false
    private var peerClosed = false
    private var closed = false
    private var idleWork: DispatchWorkItem?

    init(connection: NWConnection, server: MockServer, queue: DispatchQueue) {
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
        scheduleIdle()
    }

    func close() {
        guard !closed else { return }
        closed = true
        idleWork?.cancel()
        idleWork = nil
        connection.cancel()
        server?.remove(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.reader.append(data)
                self.process()
            }
            if isComplete || error != nil {
                self.peerClosed = true
                if !self.busy { self.close() }
                return
            }
            self.receive()
        }
    }

    private func process() {
        guard !busy, !closed else { return }
        let started = ContinuousClock.now
        switch reader.next() {
        case .needMore:
            if peerClosed { close() } else { scheduleIdle() }
        case .continueExpected:
            connection.send(content: MockHTTPWriter.continueResponse, completion: .contentProcessed { _ in })
            process()
        case .failure(let status):
            busy = true
            idleWork?.cancel()
            connection.send(content: MockHTTPWriter.error(status), completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
            server?.report(nil, route: nil, status: status, started: started)
        case .request(let request, let keepAlive):
            busy = true
            idleWork?.cancel()
            server?.route(request) { [weak self] route in
                self?.respond(request, route: route, keepAlive: keepAlive, started: started)
            }
        }
    }

    private func respond(_ request: MockIncomingRequest, route: MockRoute, keepAlive: Bool, started: ContinuousClock.Instant) {
        guard !closed else { return }
        let delay = route.response.delayMilliseconds
        let send: @Sendable () -> Void = { [weak self] in
            guard let self, !self.closed else { return }
            let reuse = keepAlive && !self.peerClosed
            let data = MockHTTPWriter.data(for: route.response, method: request.method, keepAlive: reuse)
            self.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.server?.report(request, route: route, status: route.response.status, started: started)
                self.busy = false
                if reuse { self.process() } else { self.close() }
            })
        }
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + .milliseconds(delay), execute: send)
        } else {
            send()
        }
    }

    /// Boşta (istek beklerken) kalan bağlantı süre dolunca kapanır.
    private func scheduleIdle() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.busy else { return }
            self.close()
        }
        idleWork = work
        queue.asyncAfter(deadline: .now() + MockerLimits.idleConnectionSeconds, execute: work)
    }
}
