import Darwin
import Foundation

/// Yetkilendirme callback'ini karşılayan tek seferlik yerel HTTP dinleyicisi.
///
/// RFC 8252 §7.3 native uygulamalar için loopback yönlendirmesini önerir.
/// Özel URL şeması (`secora://`) tercih edilmedi: aynı şemayı kaydeden
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
    private let queue = DispatchQueue(label: "com.secora.oauth.loopback")
    private let lock = NSLock()
    private var closed = false

    /// Port 0 verilirse işletim sistemi boş bir port seçer.
    public init(preferredPort: UInt16 = 0) throws {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw ReceiverError(message: "Yerel soket açılamadı (errno \(errno)).")
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
            throw ReceiverError(message: "Yerel port bağlanamadı (errno \(errno)).")
        }
        guard listen(handle, 1) == 0 else {
            close(handle)
            throw ReceiverError(message: "Yerel port dinlenemedi (errno \(errno)).")
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
            throw ReceiverError(message: "Yerel port öğrenilemedi (errno \(errno)).")
        }

        self.descriptor = handle
        self.port = UInt16(bigEndian: assigned.sin_port)
    }

    deinit {
        closeSocket()
    }

    /// İlk callback isteğini bekler ve çağrılan adresi döner.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let state = ContinuationBox(continuation)

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard state.finish() else { return }
                self?.closeSocket()
                state.resume(throwing: ReceiverError(message: "Yetkilendirme zaman aşımına uğradı."))
            }

            queue.async { [weak self] in
                guard let self else { return }
                do {
                    let url = try self.acceptOne()
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
    }

    public func stop() {
        closeSocket()
    }

    // MARK: - Bağlantı

    /// Callback yolunu taşıyan ilk isteği kabul eder. Tarayıcının gönderdiği
    /// favicon gibi alakasız istekler yanıtlanıp atlanır.
    private func acceptOne() throws -> URL {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                throw ReceiverError(message: "Callback beklenirken bağlantı kapandı.")
            }
            defer { close(client) }

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

    private static let successHTML = """
    <!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Secora</title>
    <style>body{font-family:-apple-system,system-ui,sans-serif;background:#130d2e;color:#f3f0fe;
    display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    .k{text-align:center}h1{color:#aa9cd5;font-size:20px}p{color:#959595;font-size:14px}</style>
    </head><body><div class="k"><h1>Yetkilendirme tamamlandı</h1>
    <p>Bu sekmeyi kapatıp Secora'ya dönebilirsin.</p></div></body></html>
    """

    private static let failureHTML = """
    <!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Secora</title>
    <style>body{font-family:-apple-system,system-ui,sans-serif;background:#130d2e;color:#f3f0fe;
    display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    .k{text-align:center}h1{color:#e23737;font-size:20px}</style>
    </head><body><div class="k"><h1>Beklenmeyen istek</h1></div></body></html>
    """
}
