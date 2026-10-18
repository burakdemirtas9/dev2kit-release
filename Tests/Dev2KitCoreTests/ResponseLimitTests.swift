import XCTest
@testable import Dev2KitCore

/// Yanıt tavanı (kullanıcı kararı, 2026-10-19: 50 MB; aşınca uyarı).
/// Yerel bir HTTP sunucusuyla, uygulamanın kendi gönderim yolundan denenir.
final class ResponseLimitTests: XCTestCase {
    private var server: Process?
    private var directory: URL!
    private var port = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-limit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        port = Int.random(in: 20_000...40_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process
        // Sunucu ayağa kalksın.
        for _ in 0..<50 {
            if (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/")!)) != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    override func tearDown() {
        server?.terminate()
        try? FileManager.default.removeItem(at: directory)
    }

    private func get(_ file: String) async throws -> ResponseData {
        let engine = RequestEngine()
        let model = RequestModel(url: "http://127.0.0.1:\(port)/\(file)")
        do {
            return try await engine.send(model, environment: nil, secretStore: InMemorySecretStore(), hostPolicy: .notConfigured)
        } catch RequestEngineError.needsApproval(let findings) {
            // Düz HTTP uyarısı: test yerel sunucuya gidiyor, onaylanır.
            return try await engine.send(model, environment: nil, secretStore: InMemorySecretStore(), hostPolicy: .notConfigured,
                                         approvedWarnings: Set(findings.compactMap(\.approvalKey)))
        }
    }

    func testLargeResponseIsCutAtTheLimitAndFlagged() async throws {
        try Data(count: 60_000_000).write(to: directory.appendingPathComponent("big.bin"))
        let start = Date()
        let response = try await get("big.bin")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(response.bodyLimitExceeded)
        XCTAssertEqual(response.body.count, RequestEngine.maxResponseBytes)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertLessThan(elapsed, 10, "parça parça okuma yavaş olmamalı (AsyncBytes 4,5 dk sürüyordu)")
    }

    func testSmallResponseIsUntouched() async throws {
        try Data(#"{"ok": true}"#.utf8).write(to: directory.appendingPathComponent("small.json"))
        let response = try await get("small.json")
        XCTAssertFalse(response.bodyLimitExceeded)
        XCTAssertEqual(response.bodyText, #"{"ok": true}"#)
    }

    func testCutInsideAMultiByteCharacterStillReadsAsText() async throws {
        // "ş" 2 bayt; tavanı tek bayt kaydırıp karakterin ortasından kestir.
        var text = Data(repeating: UInt8(ascii: "a"), count: RequestEngine.maxResponseBytes - 1)
        text.append(contentsOf: Array(String(repeating: "ş", count: 1_000).utf8))
        try text.write(to: directory.appendingPathComponent("tr.txt"))
        let response = try await get("tr.txt")
        XCTAssertTrue(response.bodyLimitExceeded)
        XCTAssertNotNil(response.bodyText, "kesik gövde metin olarak okunabilmeli")
    }
}
