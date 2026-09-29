import XCTest
@testable import Dev2KitCore

/// "Yalnızca ömür sınırına takıldı" kararı.
///
/// Test verisi UYDURMA DEĞİL: aşağıdaki sözlükler, kendi ürettiğim bir kurum
/// köküyle imzalanmış sertifikalara karşı `SecTrustCopyResult`'ın gerçekten
/// döndürdüğü değerler (macOS 26 / Darwin 27). Hata koduna bakmak yetmiyordu:
/// hostname'i de yanlış olan 10 yıllık sertifika yine -67901 veriyor.
final class TrustFailureTests: XCTestCase {

    // Ölçülen gerçek çıktılar
    private let uzunAdDogru: [[String: Any]] = [
        ["OtherTrustValidityPeriod": 0, "StatusCodes": [-2147409651]],
        [:],
    ]
    private let suresiGecmis: [[String: Any]] = [
        ["TemporalValidity": 0, "StatusCodes": [-2147409654]],
        [:],
    ]
    private let uzunAdYanlis: [[String: Any]] = [
        ["OtherTrustValidityPeriod": 0, "SSLHostname": 0, "StatusCodes": [-2147408896, -2147409651]],
        [:],
    ]

    func testOnlyValidityPeriodIsAccepted() {
        XCTAssertTrue(TrustFailure.isOnlyValidityPeriodLimit(uzunAdDogru))
    }

    func testExpiredCertificateIsStillRejected() {
        XCTAssertFalse(TrustFailure.isOnlyValidityPeriodLimit(suresiGecmis))
    }

    func testHostnameMismatchIsStillRejected() {
        // En kritik durum: ömür muafiyeti hostname kontrolünü ASLA yutmamalı.
        XCTAssertFalse(TrustFailure.isOnlyValidityPeriodLimit(uzunAdYanlis))
    }

    func testStatusCodesIsNotTreatedAsACheck() {
        XCTAssertEqual(TrustFailure.failedChecks(in: uzunAdDogru), ["OtherTrustValidityPeriod"])
    }

    func testLongValidityAndExpiredIsRejected() {
        // Hem 10 yıllık hem süresi dolmuş: muafiyet açık olsa da reddedilmeli.
        // Canlı sunucuyla da doğrulandı (10 yıl / süresi dolmuş -> RED).
        let details: [[String: Any]] = [
            ["OtherTrustValidityPeriod": 0, "TemporalValidity": 0,
             "StatusCodes": [-2147409651, -2147409654]],
            [:],
        ]
        XCTAssertFalse(TrustFailure.isOnlyValidityPeriodLimit(details))
    }

    func testFailureOnAnotherCertificateInChainCounts() {
        // Sorun ara sertifikadaysa da reddedilmeli.
        let details: [[String: Any]] = [
            ["OtherTrustValidityPeriod": 0, "StatusCodes": [-2147409651]],
            ["TemporalValidity": 0, "StatusCodes": [-2147409654]],
        ]
        XCTAssertFalse(TrustFailure.isOnlyValidityPeriodLimit(details))
    }

    func testEmptyDetailsAreNotAccepted() {
        // Bilinmeyen durumda KABUL EDİLMEZ.
        XCTAssertFalse(TrustFailure.isOnlyValidityPeriodLimit([]))
        XCTAssertFalse(TrustFailure.isOnlyValidityPeriodLimit([[:], [:]]))
    }

    func testUnknownCheckIsNotAccepted() {
        let details: [[String: Any]] = [["KeyUsage": 0, "StatusCodes": [-1]]]
        XCTAssertFalse(TrustFailure.isOnlyValidityPeriodLimit(details))
    }
}

/// Profil bayrağı varsayılan olarak KAPALI ve eski dosyalarda da kapalı.
final class LongValidityFlagTests: XCTestCase {
    func testDefaultIsOff() {
        XCTAssertFalse(TLSProfile().allowLongValidity)
    }

    func testOlderProfilesDecodeAsOff() throws {
        let json = #"{"id":"B35C839C-6B63-4854-96C9-DBF24DAC03C6","name":"eski","hostPatterns":["a.b.com"],"caCertificatePath":"","pinToCA":false,"clientCertificatePath":"","clientCertificatePassword":""}"#
        let profile = try JSONDecoder().decode(TLSProfile.self, from: Data(json.utf8))
        XCTAssertFalse(profile.allowLongValidity)
    }

    func testFlagSurvivesRoundTrip() throws {
        var profile = TLSProfile(name: "test", hostPatterns: ["a.b.com"])
        profile.allowLongValidity = true
        let data = try JSONEncoder().encode(profile)
        XCTAssertTrue(try JSONDecoder().decode(TLSProfile.self, from: data).allowLongValidity)
    }
}

/// Gerekçe metni: kullanıcı neyi düzelteceğini bilmeli.
extension TrustFailureTests {
    func testHostnameIsNamedFirst() {
        // Hem ad hem süre düşmüşse önce adı söyle: asıl engel o, süre
        // muafiyetle açılabilir ama ad uyuşmazlığı açılamaz.
        let text = TrustFailure.describe(["OtherTrustValidityPeriod", "SSLHostname"])
        XCTAssertNotNil(text)
        let hostnameIndex = text!.range(of: "adlar")?.lowerBound
        let validityIndex = text!.range(of: "398")?.lowerBound
        XCTAssertNotNil(hostnameIndex)
        XCTAssertNotNil(validityIndex)
        XCTAssertTrue(hostnameIndex! < validityIndex!, text!)
    }

    func testUnknownChecksAreStillReported() {
        // Sessizce yutma: tanımadığımız bir kontrol düştüyse adı geçsin.
        let text = TrustFailure.describe(["KeyUsage"]) ?? ""
        XCTAssertTrue(text.contains("KeyUsage"), text)
    }

    func testNoChecksMeansNoDescription() {
        XCTAssertNil(TrustFailure.describe([]))
    }
}
