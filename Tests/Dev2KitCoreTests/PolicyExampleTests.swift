import XCTest
@testable import Dev2KitCore

/// `docs/policy/policy.example.json` ve kurulum rehberindeki kalıp tablosu
/// kodla tutarlı kalsın: belge yanlış bilgi vermesin.
final class PolicyExampleTests: XCTestCase {
    private var exampleURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/policy/policy.example.json")
    }

    func testExampleFileIsAValidPolicyAndMatchesTheGuide() throws {
        guard case .active(let policy) = HostPolicyLoader.parse(try Data(contentsOf: exampleURL)) else {
            return XCTFail("örnek dosya geçerli bir politika olmalı")
        }
        // Rehberdeki tablo.
        XCTAssertTrue(policy.allows(host: "api.partner.com"))
        XCTAssertFalse(policy.allows(host: "x.api.partner.com"))
        XCTAssertFalse(policy.allows(host: "partner.com"))
        XCTAssertTrue(policy.allows(host: "api.firma.com"))
        XCTAssertTrue(policy.allows(host: "a.b.firma.com"))
        XCTAssertTrue(policy.allows(host: "firma.com"), "örnekte ayrıca yazılı")
        XCTAssertTrue(policy.allows(host: "API.FIRMA.COM."), "büyük harf ve sondaki nokta")
        XCTAssertTrue(policy.allows(host: "127.0.0.1"))
        XCTAssertFalse(policy.allows(host: "httpbin.org"), "rehberdeki doğrulama örneği engellenir")
        XCTAssertFalse(policy.allows(host: "firma.com.evil.test"))
    }

    func testGuideListsTheseAsInvalid() {
        for bad in [#"{"allowedHosts":["*"]}"#, #"{"allowedHosts":["https://a.com"]}"#, #"{"allowedHosts":["a.com/api"]}"#,
                    #"{"allowedHosts":["user@a.com"]}"#, #"{"allowedHosts":["ş.com"]}"#, #"{"allowedHost":["a.com"]}"#] {
            guard case .invalid = HostPolicyLoader.parse(Data(bad.utf8)) else { return XCTFail("geçersiz olmalı: \(bad)") }
        }
        guard case .active(let empty) = HostPolicyLoader.parse(Data(#"{"allowedHosts":[]}"#.utf8)) else { return XCTFail() }
        XCTAssertFalse(empty.allows(host: "localhost"), "boş liste hiçbir host'a izin vermez")
    }

    /// Hata mesajı dizin yolunu göstermez (kullanıcı geri bildirimi,
    /// 2026-10-24); yalnızca sorunlu öğe (dosya / klasör) ve neden.
    func testErrorMessagesDoNotRevealPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("policy.json")
        try Data(#"{"allowedHosts":["a.com"]}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        // Kullanıcıya ait dosya: root sahipliği istenince geçersiz.
        guard case .invalid(let notRoot) = HostPolicyLoader.load(from: file) else { return XCTFail("geçersiz olmalı") }
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        guard case .invalid(let writable) = HostPolicyLoader.load(from: file, requireRootOwnership: false) else { return XCTFail() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        guard case .invalid(let folderWritable) = HostPolicyLoader.load(from: file, requireRootOwnership: false) else { return XCTFail() }

        for reason in [notRoot, writable, folderWritable] {
            XCTAssertFalse(reason.contains("/"), "yol görünmemeli: \(reason)")
            XCTAssertFalse(reason.contains(directory.lastPathComponent), reason)
            let shown = HostPolicyState.invalid(reason: reason).violation(for: URL(string: "https://a.com"))
            XCTAssertFalse(shown?.contains("/Library") ?? true, shown ?? "")
        }
        XCTAssertNotEqual(writable, folderWritable, "dosya ile klasör ayrı söylenir")
    }
}

