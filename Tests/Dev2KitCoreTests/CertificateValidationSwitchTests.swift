import Foundation
import Security
import XCTest
@testable import Dev2KitCore

/// Uygulama geneli "sertifika doğrulamasını kapat" anahtarı.
///
/// Aynı sertifika iki kez değerlendiriliyor: anahtar kapalıyken REDDEDİLMESİ
/// gereken bir zincir (100 yıllık uç sertifika, 398 gün kuralına takılır),
/// anahtar açıkken kabul edilmeli. İlk yarı, testin gerçekten bir reddi
/// atladığını kanıtlıyor — her şeyi zaten kabul eden bir zincirle test
/// yazmak anahtarın çalıştığını göstermezdi.
final class CertificateValidationSwitchTests: XCTestCase {
    private func trust() throws -> SecTrust {
        let data = try XCTUnwrap(Data(base64Encoded: CertificateInspectionTests.leaf))
        let leaf = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }

    private func caCertificate() throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: CertificateInspectionTests.ca))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    private func challenge(host: String) throws -> URLAuthenticationChallenge {
        let space = FakeServerTrustSpace(host: host, trust: try trust())
        return URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: NoopChallengeSender()
        )
    }

    func testChainIsRejectedWhileValidationIsOn() throws {
        let profile = ResolvedTLSProfile(caCertificates: [try caCertificate()], pinToCA: false, identity: nil)
        let (disposition, credential, rejection) = TLSChallengeHandler.serverTrust(
            challenge: try challenge(host: "ornek.test"),
            profile: profile
        )
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
        XCTAssertNotNil(rejection)
    }

    func testSameChainIsAcceptedWhenValidationIsSkipped() throws {
        let profile = ResolvedTLSProfile(
            caCertificates: [try caCertificate()],
            pinToCA: false,
            skipValidation: true,
            identity: nil
        )
        let (disposition, credential, rejection) = TLSChallengeHandler.serverTrust(
            challenge: try challenge(host: "ornek.test"),
            profile: profile
        )
        XCTAssertEqual(disposition, .useCredential)
        XCTAssertNotNil(credential)
        XCTAssertNil(rejection)
    }

    func testSkipAppliesWithoutAnyCAOrProfile() throws {
        // Uygulama geneli: host'a uyan profil ya da güven deposu olmasa da.
        let profile = ResolvedTLSProfile(caCertificates: [], pinToCA: false, skipValidation: true, identity: nil)
        let (disposition, _, _) = TLSChallengeHandler.serverTrust(
            challenge: try challenge(host: "baska-ad.test"),
            profile: profile
        )
        XCTAssertEqual(disposition, .useCredential)
    }

    func testSkipAloneMakesProfileNonEmpty() {
        // `isEmpty` profili nil'e çeviriyor; anahtar tek başına açıkken
        // profil düşerse doğrulama sessizce yeniden devreye girerdi.
        let profile = ResolvedTLSProfile(caCertificates: [], pinToCA: false, skipValidation: true, identity: nil)
        XCTAssertFalse(profile.isEmpty)
        XCTAssertTrue(ResolvedTLSProfile(caCertificates: [], pinToCA: false, identity: nil).isEmpty)
    }

    func testEngineStartsWithValidationOn() {
        XCTAssertFalse(RequestEngine().skipCertificateValidation)
    }

    func testResponseIsMarkedValidatedByDefault() {
        let response = ResponseData(statusCode: 200, headers: [], body: Data(), duration: 0, finalURL: nil)
        XCTAssertFalse(response.certificateValidationSkipped)
    }
}

private final class FakeServerTrustSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust

    init(host: String, trust: SecTrust) {
        self.trust = trust
        super.init(
            host: host,
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
    }

    required init?(coder: NSCoder) { nil }

    override var serverTrust: SecTrust? { trust }
}

private final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
