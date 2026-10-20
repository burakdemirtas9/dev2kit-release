import XCTest
@testable import Dev2KitCore

/// Güvenlik incelemesi F2 (2026-10-20): dışa aktarılan cURL komutu terminalde
/// çalıştırılınca yerel dosya okumamalı; uygulamanın gönderdiğiyle aynı
/// metni göndermeli. Komut gerçek `/usr/bin/curl` ile yerel (127.0.0.1)
/// sunucuya çalıştırılır; dosya geçici bir sentetik kanarya.
final class CurlExportFileReadTests: XCTestCase {
    private let canaryText = "SYNTHETIC-LOCAL-FILE-CANARY"

    private func canaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-canary-\(UUID().uuidString).txt")
        try canaryText.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Komutu kabukta çalıştırır, sunucunun aldığı ham isteği döner.
    private func runExported(_ body: (String) -> RequestBody) async throws -> String {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/curl"), "curl yok")
        let canary = try canaryFile()
        let server = try LoopbackHTTPServer()
        let port = try await server.start()
        let model = RequestModel(method: .post, url: "http://127.0.0.1:\(port)/up", body: body(canary.path))
        let command = try CurlExporter.export(model, environment: nil, secretStore: InMemorySecretStore())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command + " -s -o /dev/null --max-time 5"]
        try process.run()
        process.waitUntilExit()
        return server.received.first ?? ""
    }

    func testMultipartAtValueIsSentLiterallyNotAsAFile() async throws {
        let raw = try await runExported { .multipartForm(fields: [KeyValueEntry(key: "payload", value: "@\($0)")]) }
        XCTAssertTrue(raw.contains("POST /up "), raw)
        XCTAssertFalse(raw.contains(canaryText), "dosya içeriği gitmemeli")
        XCTAssertTrue(raw.contains("@/"), "değer düz metin olarak gitmeli")
    }

    func testMultipartLessThanValueIsSentLiterally() async throws {
        let raw = try await runExported { .multipartForm(fields: [KeyValueEntry(key: "payload", value: "<\($0)")]) }
        XCTAssertTrue(raw.contains("POST /up "), raw)
        XCTAssertFalse(raw.contains(canaryText))
    }

    /// Sıkılaştırma (açık değil): `--data-urlencode` curl 8.7'de `=`'i önce
    /// aradığı için adda `@` olsa da dosya okumuyordu (eski kodda da geçiyor).
    /// Komut artık hazır kodlanmış gövde verir; hiçbir curl sürümünde okumasın.
    func testURLEncodedAtInNameDoesNotReadAFile() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/curl"), "curl yok")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-canary-\(UUID().uuidString)").path
        let fileURL = URL(fileURLWithPath: base + "=v")
        try canaryText.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let server = try LoopbackHTTPServer()
        let port = try await server.start()
        let model = RequestModel(method: .post, url: "http://127.0.0.1:\(port)/up",
                                 body: .formURLEncoded(fields: [KeyValueEntry(key: "x@" + base, value: "v")]))
        let command = try CurlExporter.export(model, environment: nil, secretStore: InMemorySecretStore())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command + " -s -o /dev/null --max-time 5"]
        try process.run()
        process.waitUntilExit()
        let raw = server.received.first ?? ""
        XCTAssertTrue(raw.contains("POST /up "), raw)
        XCTAssertFalse(raw.contains(canaryText), "dosya içeriği gitmemeli")
    }

    /// Uygulamanın gönderdiği ile komutun gönderdiği aynı değer.
    func testAppAndCurlSendTheSameMultipartValue() async throws {
        let canary = try canaryFile()
        let server = try LoopbackHTTPServer()
        let port = try await server.start()
        let model = RequestModel(method: .post, url: "http://127.0.0.1:\(port)/up",
                                 body: .multipartForm(fields: [KeyValueEntry(key: "payload", value: "@\(canary.path);type=text/plain")]))
        _ = try await RequestEngine().send(model, environment: nil, secretStore: InMemorySecretStore(), hostPolicy: .notConfigured)
        let command = try CurlExporter.export(model, environment: nil, secretStore: InMemorySecretStore())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command + " -s -o /dev/null --max-time 5"]
        try process.run()
        process.waitUntilExit()
        let requests = server.received
        XCTAssertEqual(requests.count, 2)
        let literal = "@\(canary.path);type=text/plain"
        XCTAssertTrue(requests.allSatisfy { $0.contains(literal) && !$0.contains(canaryText) })
    }

    func testHeaderNameStartingWithAtIsRefused() {
        let model = RequestModel(url: "https://api.example.com", headers: [KeyValueEntry(key: "@/etc/hosts", value: "x")])
        XCTAssertThrowsError(try CurlExporter.export(model, environment: nil, secretStore: InMemorySecretStore()))
    }
}
