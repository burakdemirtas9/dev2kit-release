import Foundation
import Network
@testable import Dev2KitCore

/// Testler için en küçük HTTP sunucusu: yalnızca 127.0.0.1, her bağlantıda
/// tek istek. Gelen ham istekleri saklar; yanıtı test belirler (yönlendirme
/// ya da 200). İki ayrı örnek iki ayrı port = iki ayrı kaynak (origin).
final class LoopbackHTTPServer: @unchecked Sendable {
    /// Ham istek → ham yanıt (durum satırı + başlıklar + gövde).
    typealias Responder = @Sendable (String) -> String

    private let listener: NWListener
    private let lock = NSLock()
    private var requests: [String] = []
    private let responder: Responder

    /// Alınan istekler (başlıklar ve gövde dahil, ham metin).
    var received: [String] { lock.lock(); defer { lock.unlock() }; return requests }

    init(responder: @escaping Responder = { _ in LoopbackHTTPServer.ok("ok") }) throws {
        self.responder = responder
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.read(connection, buffer: Data())
        }
    }

    deinit { listener.cancel() }

    static func ok(_ body: String, contentType: String = "text/plain") -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    static func redirect(_ status: Int, to location: String) -> String {
        "HTTP/1.1 \(status) Redirect\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            if let headerEnd = text.range(of: "\r\n\r\n"), Self.bodyComplete(text, headerEnd: headerEnd) || isComplete {
                self.lock.lock(); self.requests.append(text); self.lock.unlock()
                let reply = self.responder(text)
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if !isComplete {
                self.read(connection, buffer: buffer)
            }
        }
    }

    /// Content-Length kadar gövde geldi mi.
    private static func bodyComplete(_ text: String, headerEnd: Range<String.Index>) -> Bool {
        let head = text[..<headerEnd.lowerBound].lowercased()
        guard let line = head.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
              let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) else {
            return true
        }
        return text[headerEnd.upperBound...].utf8.count >= length
    }

    /// Dinlemeye başlar ve portu döner.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = NSLock()
            var done = false
            listener.stateUpdateHandler = { [listener] state in
                resumed.lock(); defer { resumed.unlock() }
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    done = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
}

extension RequestEngine {
    /// Testte gönderim: güvenlik uyarıları (secret yeni host'a gidiyor) varsa
    /// kullanıcının onaylaması gibi hepsi onaylanıp yeniden gönderilir.
    func sendApprovingWarnings(_ model: RequestModel, environment: EnvironmentModel? = nil, secretStore: SecretStore) async throws -> ResponseData {
        do {
            return try await send(model, environment: environment, secretStore: secretStore, hostPolicy: .notConfigured)
        } catch RequestEngineError.needsApproval(let findings) {
            return try await send(model, environment: environment, secretStore: secretStore, hostPolicy: .notConfigured,
                                  approvedWarnings: Set(findings.compactMap(\.approvalKey)))
        }
    }
}
