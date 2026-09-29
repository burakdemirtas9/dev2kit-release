import XCTest
@testable import Dev2KitCore

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
            .appendingPathComponent("dev2kit-tls-\(UUID().uuidString)")
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
            .appendingPathComponent("dev2kit-truststore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSearchPathsAreStable() {
        XCTAssertTrue(TrustStore.machineDirectory.path.hasPrefix("/Library/Application Support/dev2kit"))
        XCTAssertTrue(TrustStore.userDirectory.path.contains("dev2kit"))
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
        XCTAssertThrowsError(try TrustStore.remove(path: "/Library/Application Support/dev2kit/cacerts/x.pem")) { error in
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
        // Kullanıcının gerçek cacerts dizinine DOKUNULMAZ: ortam değişkeniyle
        // geçici dizin kullanılır (testler canlı veriyle çalışmamalı).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev2kit-cacerts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        setenv(TrustStore.environmentVariable, directory.path, 1)
        defer { unsetenv(TrustStore.environmentVariable) }

        let bogus = directory.appendingPathComponent("gecici-test-bozuk.pem")
        try Data("sertifika değil".utf8).write(to: bogus)

        let result = TrustStore.load()
        XCTAssertTrue(result.problems.contains { $0.contains("gecici-test-bozuk.pem") })
    }
}

/// CA seçilmemişken sabitleme: kutu bir güvenlik özelliği vaat ediyor ama
/// veremiyor. Motor bunu etkisiz saymalı, yoksa güven deposu da düşüyordu.
final class PinningWithoutCATests: XCTestCase {
    private func profile(ca: String, pin: Bool) -> TLSProfile {
        TLSProfile(hostPatterns: ["api.firma.com"], caCertificatePath: ca, pinToCA: pin)
    }

    func testPinningWithCAIsEffective() {
        let subject = profile(ca: "/tmp/ca.pem", pin: true)
        XCTAssertTrue(subject.isPinningEffective)
        XCTAssertFalse(subject.pinsWithoutCA)
    }

    func testPinningWithoutCAIsReportedAndIneffective() {
        let subject = profile(ca: "", pin: true)
        XCTAssertTrue(subject.pinsWithoutCA)
        XCTAssertFalse(subject.isPinningEffective)
    }

    func testWhitespaceOnlyPathCountsAsNoCA() {
        XCTAssertTrue(profile(ca: "   ", pin: true).pinsWithoutCA)
    }

    func testPinningOffIsNeverAProblem() {
        let subject = profile(ca: "", pin: false)
        XCTAssertFalse(subject.pinsWithoutCA)
        XCTAssertFalse(subject.isPinningEffective)
    }
}

/// TLS reddinin sessizce yutulmaması.
///
/// URLSession `cancelAuthenticationChallenge`'ı kullanıcı iptaliyle AYNI
/// kodla (-999) raporluyor. Ayırt edilmezse güvenlik gerekçeli bir red
/// "istek iptal edildi" sanılıp ekrana hiçbir şey yansımıyordu.
final class TLSRejectionErrorTests: XCTestCase {
    func testMessageNamesHostAndReason() {
        let error = RequestEngineError.tlsRejected(
            host: "api.firma.local",
            reason: "kök sertifika bulunamadı"
        )
        let message = error.localizedDescription
        XCTAssertTrue(message.contains("api.firma.local"), message)
        XCTAssertTrue(message.contains("kök sertifika bulunamadı"), message)
    }

    func testMessageTellsWhatToDo() {
        let message = RequestEngineError.tlsRejected(host: "h", reason: "r").localizedDescription
        XCTAssertTrue(message.contains("Güven Deposu"), message)
        XCTAssertTrue(message.contains("Host Profilleri"), message)
    }

    func testMessageStatesVerificationIsNeverSkipped() {
        // Kullanıcı bu hatayı görünce arayacağı ilk şey "doğrulamayı kapat"
        // seçeneği olur; mesaj öyle bir şey olmadığını PEŞİNEN söylemeli.
        // (Alt dize aramakla yetinmek yanıltıcı: "atla" zaten "atlanmaz"
        // içinde geçiyor.)
        let message = RequestEngineError.tlsRejected(host: "h", reason: "r").localizedDescription
        XCTAssertTrue(message.contains("atlanmaz"), message)
    }
}

/// Güven hatasının gerekçesi anlaşılır olmalı.
///
/// Apple 1 Eylül 2020'den sonra düzenlenmiş SUNUCU sertifikalarında 398
/// günden uzun geçerlilik kabul etmiyor ve hatayı "standartlarla uyumlu
/// değil" diye veriyor — kullanıcıya hiçbir şey anlatmayan bir cümle.
/// Ölçüldü: aynı kurum köküyle imzalı 300 günlük sertifika geçiyor,
/// 10 yıllık `-67901` ile düşüyor.
final class TLSRejectionReasonTests: XCTestCase {
    private func osStatusError(_ code: OSStatus) -> CFError {
        CFErrorCreate(nil, NSOSStatusErrorDomain as CFString, CFIndex(code), nil)
    }

    func testValidityPeriodIsExplainedInPlainWords() {
        let reason = TLSChallengeHandler.explain(osStatusError(errSecCertificateValidityPeriodTooLong))
        XCTAssertTrue(reason.contains("398"), reason)
        XCTAssertTrue(reason.contains("sunucu sertifikas"), reason)
        // Kökün süresiyle karıştırılmasın: kullanıcı yanlış sertifikayı değiştirmeye kalkmasın.
        XCTAssertTrue(reason.lowercased().contains("kök"), reason)
    }

    func testOtherErrorsKeepSystemWording() {
        let reason = TLSChallengeHandler.explain(osStatusError(errSecCertificateExpired))
        XCTAssertFalse(reason.contains("398"), reason)
        XCTAssertFalse(reason.isEmpty)
    }

    func testMissingErrorFallsBack() {
        XCTAssertEqual(TLSChallengeHandler.explain(nil), "sertifika zinciri doğrulanamadı")
    }
}

/// Reddi KİMİN verdiği ayrılmalı.
///
/// Bizim reddimizde gerekçe bizde; sistem reddettiğinde karar bizim değil ve
/// elimizde yalnızca sunucunun sertifikasının künyesi var. İkisi aynı yerden
/// akıyor ama farklı mesaj üretiyor.
final class TLSRejectionOriginTests: XCTestCase {
    func testOurRejectionCarriesReason() {
        let rejection = TLSChallengeHandler.Rejection(
            host: "a.firma.local",
            reason: "sertifikadaki adlar bu host ile eşleşmiyor"
        )
        XCTAssertTrue(rejection.isOurs)
    }

    func testSystemRejectionOnlyCarriesNames() {
        let rejection = TLSChallengeHandler.Rejection(
            host: "a.firma.local",
            reason: "",
            presentedNames: "*.firma.local"
        )
        XCTAssertFalse(rejection.isOurs)
        XCTAssertEqual(rejection.presentedNames, "*.firma.local")
    }

    func testCertificateFailureCodesAreCovered() {
        // Sunucu sertifikasıyla ilgili hatalarda künye eklenmeli.
        for code in [URLError.Code.serverCertificateUntrusted,
                     .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot,
                     .serverCertificateNotYetValid,
                     .secureConnectionFailed] {
            XCTAssertTrue(RequestEngine.tlsFailureCodes.contains(code), "\(code)")
        }
        // Zaman aşımı sertifika hatası değil; künye eklenmemeli.
        XCTAssertFalse(RequestEngine.tlsFailureCodes.contains(.timedOut))
    }
}

/// Host kalıbı olmayan profil hiçbir şey yapmaz — ve bunu söylemek gerekir.
final class ProfileScopeTests: XCTestCase {
    func testProfileWithNoPatternsAppliesToNothing() {
        let profile = TLSProfile(name: "p", hostPatterns: [], caCertificatePath: "/tmp/ca.pem")
        XCTAssertTrue(profile.appliesToNothing)
        XCTAssertFalse(profile.applies(to: "api.firma.local"))
    }

    func testBlankPatternsCountAsNone() {
        let profile = TLSProfile(name: "p", hostPatterns: ["", "   "])
        XCTAssertTrue(profile.appliesToNothing)
    }

    func testOnlyInvalidPatternsCountAsNone() {
        // Tek başına "*" kabul edilmiyor; geriye uygulanabilir kalıp kalmıyor.
        let profile = TLSProfile(name: "p", hostPatterns: ["*"])
        XCTAssertTrue(profile.appliesToNothing)
    }

    func testOneValidPatternIsEnough() {
        let profile = TLSProfile(name: "p", hostPatterns: ["*", "api.firma.local"])
        XCTAssertFalse(profile.appliesToNothing)
        XCTAssertTrue(profile.applies(to: "api.firma.local"))
    }
}
