import Foundation
import Network
import XCTest
@testable import Dev2KitCore

/// Gövdeli GET'in gerçekten gönderildiği uçtan uca ölçüm: yerel (127.0.0.1)
/// bir dinleyici isteği alır ve gövdesiz geldiğini doğrular. Eskiden motor
/// bu isteği `bodyNotAllowed` ile ağa çıkarmadan durduruyordu.
final class GetBodyEndToEndTests: XCTestCase {
    /// Tek isteğe yanıt veren en küçük HTTP sunucusu; gelen ham isteği saklar.
    private final class TinyServer: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var raw = Data()
        var received: String { lock.lock(); defer { lock.unlock() }; return String(decoding: raw, as: UTF8.self) }

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                self?.read(connection)
            }
        }

        private func read(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
                guard let self else { return }
                if let data { self.lock.lock(); self.raw.append(data); self.lock.unlock() }
                if self.received.contains("\r\n\r\n") {
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    self.read(connection)
                }
            }
        }

        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                var resumed = false
                listener.stateUpdateHandler = { [listener] state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: .global())
            }
        }
    }

    private func send(_ method: HTTPMethod, body: RequestBody) async throws -> (ResponseData, String) {
        let server = try TinyServer()
        let port = try await server.start()
        defer { server.listener.cancel() }
        let model = RequestModel(method: method, url: "http://127.0.0.1:\(port)/ara", body: body)
        let response = try await RequestEngine().send(
            model, environment: nil, secretStore: InMemorySecretStore(), hostPolicy: .notConfigured
        )
        return (response, server.received)
    }

    func testGetWithBodyIsSentWithoutBodyAndFlagged() async throws {
        let (response, raw) = try await send(.get, body: .raw(content: #"{"a": bozuk"#, contentType: "application/json"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.requestBodyOmitted)
        XCTAssertTrue(raw.hasPrefix("GET /ara "), raw)
        XCTAssertFalse(raw.contains("bozuk"), "gövde tele çıkmamalı")
        XCTAssertEqual(response.bodyText, "ok", "sunucu yanıtına bildirim eklenmez")
    }

    func testGetWithEmptyBodyIsNotFlagged() async throws {
        let (response, _) = try await send(.get, body: .raw(content: "", contentType: "application/json"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(response.requestBodyOmitted)
    }

    func testPostStillSendsBody() async throws {
        let (response, raw) = try await send(.post, body: .raw(content: #"{"a":1}"#, contentType: "application/json"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(response.requestBodyOmitted)
        // Gövde başlıklardan sonra aynı ya da sonraki pakette gelebilir;
        // en azından uzunluk başlığı gövdenin gittiğini söyler.
        XCTAssertTrue(raw.lowercased().contains("content-length: 7"), raw)
    }
}
