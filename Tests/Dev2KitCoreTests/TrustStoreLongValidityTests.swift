import Foundation
import Security
import XCTest
@testable import Dev2KitCore

/// Güven deposundaki CA'lar için ömür sınırı muafiyeti.
///
/// Sahadaki vaka: kurum CA'sı güven deposuna konmuş, sunucu sertifikası
/// 825 günden uzun (AD CS şablonu). Muafiyet yalnızca host profilinde
/// olduğu için kullanıcı CA'yı profile taşıyıp host yazmak zorunda kalıyordu.
///
/// Fixture: test CA'sı ve onun imzaladığı 100 yıllık `ornek.test` sertifikası.
/// Ölçüldü: sınır 825 gün (825 geçiyor, 826 düşüyor); 100 yıllık sertifika
/// yalnızca ömür kontrolünden düşüyor.
final class TrustStoreLongValidityTests: XCTestCase {
    private func certificate(_ base64: String) throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    private func challenge(host: String) throws -> URLAuthenticationChallenge {
        let leaf = try certificate(CertificateInspectionTests.leaf)
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        return URLAuthenticationChallenge(
            protectionSpace: FakeServerTrustSpace(host: host, trust: try XCTUnwrap(trust)),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: NoopChallengeSender()
        )
    }

    private func disposition(
        host: String = "ornek.test",
        anchors: [SecCertificate]
    ) throws -> URLSession.AuthChallengeDisposition {
        let ca = try certificate(CertificateInspectionTests.ca)
        let profile = ResolvedTLSProfile(
            caCertificates: [ca],
            pinToCA: false,
            longValidityAnchors: anchors,
            identity: nil
        )
        return TLSChallengeHandler.serverTrust(challenge: try challenge(host: host), profile: profile).0
    }

    // MARK: - Muafiyet

    func testRejectedWithoutExemption() throws {
        XCTAssertEqual(try disposition(anchors: []), .cancelAuthenticationChallenge)
    }

    func testAcceptedWhenChainEndsAtExemptedTrustStoreCA() throws {
        let ca = try certificate(CertificateInspectionTests.ca)
        XCTAssertEqual(try disposition(anchors: [ca]), .useCredential)
    }

    func testHostnameMismatchIsStillRejected() throws {
        // En kritik durum: ömür muafiyeti ad kontrolünü ASLA yutmamalı.
        let ca = try certificate(CertificateInspectionTests.ca)
        XCTAssertEqual(try disposition(host: "baska.test", anchors: [ca]), .cancelAuthenticationChallenge)
    }

    func testExemptionDoesNotApplyToChainsEndingElsewhere() throws {
        // Muaf listesinde zincirin çıpası yoksa (ör. zincir başka bir köke
        // çıkıyor) kural aynen uygulanır.
        let leaf = try certificate(CertificateInspectionTests.leaf)
        XCTAssertEqual(try disposition(anchors: [leaf]), .cancelAuthenticationChallenge)
    }

    // MARK: - Zincir çıpası

    func testChainEndsAtMatchingAnchor() throws {
        let ca = try certificate(CertificateInspectionTests.ca)
        let leaf = try certificate(CertificateInspectionTests.leaf)
        XCTAssertTrue(TrustFailure.chain([leaf, ca], endsAtOneOf: [ca]))
    }

    func testChainDoesNotEndAtUnrelatedAnchor() throws {
        let ca = try certificate(CertificateInspectionTests.ca)
        let leaf = try certificate(CertificateInspectionTests.leaf)
        XCTAssertFalse(TrustFailure.chain([leaf, ca], endsAtOneOf: [leaf]))
    }

    func testEmptyInputsNeverMatch() throws {
        let ca = try certificate(CertificateInspectionTests.ca)
        XCTAssertFalse(TrustFailure.chain([], endsAtOneOf: [ca]))
        XCTAssertFalse(TrustFailure.chain([ca], endsAtOneOf: []))
    }

    func testEngineStartsWithoutExemption() {
        XCTAssertFalse(RequestEngine().trustStoreAllowsLongValidity)
    }
}
