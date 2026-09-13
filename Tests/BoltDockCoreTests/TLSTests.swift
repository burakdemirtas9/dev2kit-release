import XCTest
@testable import BoltDockCore

final class HostPatternTests: XCTestCase {
    // MARK: - Geçerlilik

    func testExactHostIsValid() {
        XCTAssertTrue(HostPattern.isValid("api.firma.com"))
    }

    func testSingleLevelWildcardIsValid() {
        XCTAssertTrue(HostPattern.isValid("*.firma.com"))
    }

    func testBareWildcardIsRejected() {
        // "*" profili tüm internete uygular; istemci kimliğini her sunucuya sızdırır.
        XCTAssertFalse(HostPattern.isValid("*"))
        XCTAssertFalse(HostPattern.isValid("*."))
    }

    func testTopLevelWildcardIsRejected() {
        XCTAssertFalse(HostPattern.isValid("*.com"))
    }

    func testMidPatternWildcardIsRejected() {
        XCTAssertFalse(HostPattern.isValid("api.*.com"))
        XCTAssertFalse(HostPattern.isValid("*.fir*.com"))
    }

    func testEmptyOrSpacedIsRejected() {
        XCTAssertFalse(HostPattern.isValid(""))
        XCTAssertFalse(HostPattern.isValid("api firma.com"))
    }

    // MARK: - Eşleşme

    func testExactMatch() {
        XCTAssertTrue(HostPattern.matches("api.firma.com", host: "api.firma.com"))
        XCTAssertFalse(HostPattern.matches("api.firma.com", host: "baska.firma.com"))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(HostPattern.matches("API.Firma.com", host: "api.firma.COM"))
    }

    func testWildcardMatchesOneLabel() {
        XCTAssertTrue(HostPattern.matches("*.firma.com", host: "api.firma.com"))
        XCTAssertTrue(HostPattern.matches("*.firma.com", host: "auth.firma.com"))
    }

    func testWildcardDoesNotMatchMultipleLabels() {
        // Tarayıcı davranışı: *.firma.com, a.b.firma.com'u kapsamaz.
        XCTAssertFalse(HostPattern.matches("*.firma.com", host: "a.b.firma.com"))
    }

    func testWildcardDoesNotMatchBareDomain() {
        XCTAssertFalse(HostPattern.matches("*.firma.com", host: "firma.com"))
    }

    func testWildcardDoesNotMatchSuffixTrick() {
        // "evilfirma.com" sonek olarak benzese de eşleşmemeli.
        XCTAssertFalse(HostPattern.matches("*.firma.com", host: "api.evilfirma.com"))
        XCTAssertFalse(HostPattern.matches("firma.com", host: "evilfirma.com"))
    }

    func testInvalidPatternNeverMatches() {
        XCTAssertFalse(HostPattern.matches("*", host: "herhangi.com"))
    }

    func testMatchesAny() {
        let patterns = ["api.firma.com", "*.test.firma.com"]
        XCTAssertTrue(HostPattern.matchesAny(patterns, host: "api.firma.com"))
        XCTAssertTrue(HostPattern.matchesAny(patterns, host: "a.test.firma.com"))
        XCTAssertFalse(HostPattern.matchesAny(patterns, host: "baska.com"))
    }
}

final class TLSProfileTests: XCTestCase {
    func testProfileAppliesToMatchingHost() {
        let profile = TLSProfile(name: "Kurum", hostPatterns: ["*.firma.com"])
        XCTAssertTrue(profile.applies(to: "api.firma.com"))
        XCTAssertFalse(profile.applies(to: "api.baska.com"))
    }

    func testSpecificProfileWinsOverWildcard() {
        let wildcard = TLSProfile(name: "Genel", hostPatterns: ["*.firma.com"])
        let specific = TLSProfile(name: "Özel", hostPatterns: ["api.firma.com"])
        // Geniş bir joker, özel bir kuralı ezmemeli.
        let selected = TLSProfile.profile(for: "api.firma.com", in: [wildcard, specific])
        XCTAssertEqual(selected?.name, "Özel")
    }

    func testNoProfileForUnmatchedHost() {
        let profile = TLSProfile(name: "Kurum", hostPatterns: ["*.firma.com"])
        XCTAssertNil(TLSProfile.profile(for: "example.com", in: [profile]))
    }

    func testInvalidPatternsAreReported() {
        let profile = TLSProfile(name: "Hatalı", hostPatterns: ["api.firma.com", "*", "*.com"])
        XCTAssertEqual(profile.invalidPatterns, ["*", "*.com"])
    }

    func testDecodingLegacyProfileFillsDefaults() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Eski"}"#
        let profile = try JSONDecoder().decode(TLSProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.name, "Eski")
        XCTAssertTrue(profile.hostPatterns.isEmpty)
        XCTAssertFalse(profile.pinToCA)
        XCTAssertFalse(profile.hasCA)
    }

    func testCapabilityFlags() {
        var profile = TLSProfile()
        XCTAssertFalse(profile.hasCA)
        XCTAssertFalse(profile.hasClientCertificate)
        profile.caCertificatePath = "/tmp/ca.pem"
        profile.clientCertificatePath = "/tmp/client.p12"
        XCTAssertTrue(profile.hasCA)
        XCTAssertTrue(profile.hasClientCertificate)
    }
}

final class CertificateLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("boltdock-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try CertificateLoader.loadCertificates(atPath: "/yok/olmayan.pem"))
    }

    func testGarbageFileThrows() throws {
        let path = directory.appendingPathComponent("bozuk.pem")
        try Data("bu bir sertifika değil".utf8).write(to: path)
        XCTAssertThrowsError(try CertificateLoader.loadCertificates(atPath: path.path))
    }

    func testPEMBlockExtraction() {
        let pem = """
        yorum satırı
        -----BEGIN CERTIFICATE-----
        \(Data("birinci".utf8).base64EncodedString())
        -----END CERTIFICATE-----
        araya metin
        -----BEGIN CERTIFICATE-----
        \(Data("ikinci".utf8).base64EncodedString())
        -----END CERTIFICATE-----
        """
        let blocks = CertificateLoader.pemBlocks(in: Data(pem.utf8))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(String(decoding: blocks[0], as: UTF8.self), "birinci")
        XCTAssertEqual(String(decoding: blocks[1], as: UTF8.self), "ikinci")
    }

    func testDERFileReturnsNoPEMBlocks() {
        // DER ikili veridir; PEM ayrıştırıcı boş dönmeli ki ham veri kullanılsın.
        let der = Data([0x30, 0x82, 0x01, 0x0a])
        XCTAssertTrue(CertificateLoader.pemBlocks(in: der).isEmpty)
    }

    func testMissingIdentityFileThrows() {
        XCTAssertThrowsError(try CertificateLoader.loadIdentity(atPath: "/yok/olmayan.p12", password: "x"))
    }

    func testInvalidP12Throws() throws {
        let path = directory.appendingPathComponent("bozuk.p12")
        try Data("p12 değil".utf8).write(to: path)
        XCTAssertThrowsError(try CertificateLoader.loadIdentity(atPath: path.path, password: "x"))
    }
}

final class TrustStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("boltdock-truststore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSearchPathsAreStable() {
        XCTAssertTrue(TrustStore.machineDirectory.path.hasPrefix("/Library/Application Support/BoltDock"))
        XCTAssertTrue(TrustStore.userDirectory.path.contains("BoltDock"))
        XCTAssertEqual(TrustStore.userDirectory.lastPathComponent, "cacerts")
        XCTAssertEqual(TrustStore.machineDirectory.lastPathComponent, "cacerts")
    }

    func testInstallRejectsInvalidCertificate() throws {
        let bogus = directory.appendingPathComponent("bozuk.pem")
        try Data("sertifika değil".utf8).write(to: bogus)
        // Bozuk dosyayı depoya koymak, her açılışta hata üretmek demek olurdu.
        XCTAssertThrowsError(try TrustStore.install(from: bogus))
    }

    func testRemoveRefusesOutsideUserDirectory() {
        XCTAssertThrowsError(try TrustStore.remove(path: "/Library/Application Support/BoltDock/cacerts/x.pem")) { error in
            XCTAssertTrue(error.localizedDescription.contains("yönetici"))
        }
    }

    func testEnvironmentDirectoriesParsing() {
        // Ortam değişkeni ayarlı değilken boş dönmeli.
        if ProcessInfo.processInfo.environment[TrustStore.environmentVariable] == nil {
            XCTAssertTrue(TrustStore.environmentDirectories().isEmpty)
        }
    }

    func testLoadReportsUnreadableFilesInsteadOfFailing() throws {
        // Yükleme bozuk dosyada çökmemeli, sorunu raporlamalı.
        let store = try TrustStore.prepareUserDirectory()
        let bogus = store.appendingPathComponent("gecici-test-bozuk.pem")
        try Data("sertifika değil".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        let result = TrustStore.load()
        XCTAssertTrue(result.problems.contains { $0.contains("gecici-test-bozuk.pem") })
    }
}
