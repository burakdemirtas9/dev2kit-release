import Darwin
import Foundation

/// Yetkilendirme callback'ini karşılayan tek seferlik yerel HTTP dinleyicisi.
///
/// RFC 8252 §7.3 native uygulamalar için loopback yönlendirmesini önerir.
/// Özel URL şeması (`dev2kit://`) tercih edilmedi: aynı şemayı kaydeden
/// başka bir uygulama callback'i kapabilir. Loopback'te böyle bir yarış yok.
///
/// Güvenlik kısıtları:
/// - Soket açıkça `INADDR_LOOPBACK`'e bağlanır. `INADDR_ANY` olsaydı yerel
///   ağdaki başka bir makine yetkilendirme kodunu yakalayabilirdi.
/// - İlk callback isteğinden sonra soket kapanır.
/// - Zaman aşımı vardır; kullanıcı tarayıcıda vazgeçerse port açık kalmaz.
///
/// POSIX soketleri kullanılıyor (Network framework değil): tek seferlik,
/// tek bağlantılı bir dinleyici için yeterli ve bağlanma kısıtı burada
/// doğrudan görünür.
public final class LoopbackReceiver: @unchecked Sendable {
    public struct ReceiverError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public let port: UInt16
    public var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    private let descriptor: Int32
    private let queue = DispatchQueue(label: "com.dev2kit.oauth.loopback")
    private let lock = NSLock()
    private var closed = false

    /// Port 0 verilirse işletim sistemi boş bir port seçer.
    public init(preferredPort: UInt16 = 0) throws {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw ReceiverError(message: L10n.t("loopback.socket", String(errno)))
        }

        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = preferredPort.bigEndian
        // 127.0.0.1 — yalnızca bu makine. INADDR_ANY kullanılmıyor.
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(handle)
            throw ReceiverError(message: L10n.t("loopback.bind", String(errno)))
        }
        guard listen(handle, 1) == 0 else {
            close(handle)
            throw ReceiverError(message: L10n.t("loopback.listen", String(errno)))
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else {
            close(handle)
            throw ReceiverError(message: L10n.t("loopback.port", String(errno)))
        }

        self.descriptor = handle
        self.port = UInt16(bigEndian: assigned.sin_port)
    }

    deinit {
        closeSocket()
    }

    /// İlk callback isteğini bekler ve çağrılan adresi döner.
    ///
    /// Süre sınırı bekleme döngüsünün içinde: eskiden zamanlayıcı ile
    /// engelleyen `accept` AYNI seri kuyruktaydı, `accept` kuyruğu tuttuğu
    /// için zamanlayıcı hiç çalışmıyordu; hiç bağlantı gelmezse ya da yerel
    /// bir süreç bağlanıp sessiz kalırsa bekleme bitmiyordu (güvenlik
    /// incelemesi, 2026-10-20). Görev iptal edilirse soket kapanır.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = ContinuationBox(continuation)
                queue.async { [weak self] in
                    guard let self else { return }
                    do {
                        let url = try self.acceptOne(deadline: deadline)
                        guard state.finish() else { return }
                        self.closeSocket()
                        state.resume(returning: url)
                    } catch {
                        guard state.finish() else { return }
                        self.closeSocket()
                        state.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.closeSocket()
        }
    }

    public func stop() {
        closeSocket()
    }

    // MARK: - Bağlantı

    /// Callback yolunu taşıyan ilk isteği kabul eder. Tarayıcının gönderdiği
    /// favicon gibi alakasız istekler yanıtlanıp atlanır.
    private func acceptOne(deadline: Date) throws -> URL {
        while true {
            guard !isClosed else { throw ReceiverError(message: L10n.t("loopback.closed")) }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ReceiverError(message: L10n.t("loopback.timeout")) }
            // Kısa dilimlerle bekle: süre ve kapatma isteği her dilimde denetlenir.
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining, 0.25) * 1000))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw ReceiverError(message: L10n.t("loopback.closed"))
            }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                if isClosed { throw ReceiverError(message: L10n.t("loopback.closed")) }
                continue
            }
            defer { close(client) }
            // Bağlanıp hiçbir şey göndermeyen istemci beklemeyi kilitlemesin:
            // okuma kalan süreyle sınırlı.
            var limit = timeval(tv_sec: Int(max(remaining, 0.1)), tv_usec: Int32((max(remaining, 0.1).truncatingRemainder(dividingBy: 1)) * 1_000_000))
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(client, &buffer, buffer.count)
            guard count > 0,
                  let request = String(bytes: buffer[0..<count], encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n").first,
                  let path = requestLine.split(separator: " ").dropFirst().first,
                  let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
                send(Self.failureHTML, to: client)
                continue
            }
            guard url.path == "/callback" else {
                send(Self.failureHTML, to: client)
                continue
            }
            send(Self.successHTML, to: client)
            return url
        }
    }

    private func send(_ body: String, to client: Int32) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        Array(response.utf8).withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            var written = 0
            while written < pointer.count {
                let result = write(client, base + written, pointer.count - written)
                if result <= 0 { break }
                written += result
            }
        }
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func closeSocket() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        close(descriptor)
    }

    /// Devamlılığın tam olarak bir kez sürdürülmesini garantiler
    /// (zaman aşımı ile kabul yarışabilir).
    private final class ContinuationBox: @unchecked Sendable {
        private let continuation: CheckedContinuation<URL, Error>
        private let lock = NSLock()
        private var done = false

        init(_ continuation: CheckedContinuation<URL, Error>) {
            self.continuation = continuation
        }

        func finish() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }

        func resume(returning url: URL) { continuation.resume(returning: url) }
        func resume(throwing error: Error) { continuation.resume(throwing: error) }
    }

    private static var successHTML: String { """
    <!doctype html><html lang="\(L10n.language.rawValue)"><head><meta charset="utf-8"><title>dev2kit</title>
    <style>body{font-family:-apple-system,system-ui,sans-serif;background:#130d2e;color:#f3f0fe;
    display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    .k{text-align:center}h1{color:#aa9cd5;font-size:20px}p{color:#959595;font-size:14px}</style>
    </head><body><div class="k"><h1>\(L10n.t("loopback.success.title"))</h1>
    <p>\(L10n.t("loopback.success.body"))</p></div></body></html>
    """ }

    private static var failureHTML: String { """
    <!doctype html><html lang="\(L10n.language.rawValue)"><head><meta charset="utf-8"><title>dev2kit</title>
    <style>body{font-family:-apple-system,system-ui,sans-serif;background:#130d2e;color:#f3f0fe;
    display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    .k{text-align:center}h1{color:#e23737;font-size:20px}</style>
    </head><body><div class="k"><h1>\(L10n.t("loopback.failure.title"))</h1></div></body></html>
    """ }
}
