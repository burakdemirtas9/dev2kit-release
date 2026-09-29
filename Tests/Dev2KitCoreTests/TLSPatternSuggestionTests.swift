import XCTest
@testable import Dev2KitCore

final class TLSPatternSuggestionTests: XCTestCase {
    private func profile(
        _ name: String,
        _ patterns: [String],
        clientCertificate: Bool = false
    ) -> TLSProfile {
        TLSProfile(
            name: name,
            hostPatterns: patterns,
            caCertificatePath: "/tmp/ca.pem",
            clientCertificatePath: clientCertificate ? "/tmp/kimlik.p12" : ""
        )
    }

    // MARK: - Öneri çıkan durumlar

    func testDifferentTLDSameOrganization() {
        let profiles = [profile("İç Servisler", ["*.firmaadi.com"])]
        let match = TLSPatternSuggestion.suggestion(for: "api.firmaadi.local", in: profiles)
        XCTAssertEqual(match?.profileName, "İç Servisler")
        XCTAssertEqual(match?.matchedPattern, "*.firmaadi.com")
        XCTAssertTrue(match?.isNonPublicSuffix == true)
    }

    func testSuggestedHostIsExactNeverWildcard() {
        let profiles = [profile("P", ["*.firmaadi.com"])]
        let match = TLSPatternSuggestion.suggestion(for: "api.firmaadi.local", in: profiles)
        XCTAssertEqual(match?.hostToAdd, "api.firmaadi.local")
    }

    func testDeeperSubdomainSameTLD() {
        // *.firmaadi.com tek seviye joker: a.b.firmaadi.com eşleşmiyor.
        let profiles = [profile("P", ["*.firmaadi.com"])]
        XCTAssertNotNil(TLSPatternSuggestion.suggestion(for: "a.b.firmaadi.com", in: profiles))
    }

    func testBareDomainAgainstWildcard() {
        // Çıplak firmaadi.com da *.firmaadi.com ile eşleşmiyor.
        let profiles = [profile("P", ["*.firmaadi.com"])]
        XCTAssertNotNil(TLSPatternSuggestion.suggestion(for: "firmaadi.com", in: profiles))
    }

    func testMultiPartPublicSuffix() {
        // firmaadi.com.tr'de kurum etiketi "com" değil "firmaadi".
        let profiles = [profile("P", ["*.firmaadi.com.tr"])]
        XCTAssertNotNil(TLSPatternSuggestion.suggestion(for: "api.firmaadi.local", in: profiles))
    }

    func testExactHostPatternAlsoProducesSuggestion() {
        let profiles = [profile("P", ["api.firmaadi.com"])]
        XCTAssertEqual(
            TLSPatternSuggestion.suggestion(for: "api.firmaadi.local", in: profiles)?.matchedPattern,
            "api.firmaadi.com"
        )
    }

    func testClientCertificateIsReported() {
        let profiles = [profile("mTLS", ["*.firmaadi.com"], clientCertificate: true)]
        let match = TLSPatternSuggestion.suggestion(for: "api.firmaadi.local", in: profiles)
        XCTAssertTrue(match?.carriesClientCertificate == true)
    }

    func testPublicSuffixIsNotFlaggedAsLocal() {
        let profiles = [profile("P", ["*.firmaadi.local"])]
        let match = TLSPatternSuggestion.suggestion(for: "api.firmaadi.com", in: profiles)
        XCTAssertFalse(match?.isNonPublicSuffix == true)
    }

    func testFirstMatchingProfileWins() {
        let profiles = [
            profile("Birinci", ["*.firmaadi.com"]),
            profile("İkinci", ["*.firmaadi.net"]),
        ]
        XCTAssertEqual(
            TLSPatternSuggestion.suggestion(for: "api.firmaadi.local", in: profiles)?.profileName,
            "Birinci"
        )
    }

    // MARK: - Öneri ÇIKMAYAN durumlar

    func testNoSuggestionWhenProfileAlreadyMatches() {
        let profiles = [profile("P", ["*.firmaadi.com"])]
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "api.firmaadi.com", in: profiles))
    }

    func testDifferentOrganizationIsNeverSuggested() {
        let profiles = [profile("P", ["*.baskafirma.com"])]
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "api.firmaadi.local", in: profiles))
    }

    func testGenericLabelIsNotAnOrganization() {
        // "dev" üzerinden bağ kurmak anlamsız.
        let profiles = [profile("P", ["*.dev.com"])]
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "api.dev.local", in: profiles))
    }

    func testShortLabelIsRejected() {
        let profiles = [profile("P", ["*.ab.com"])]
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "api.ab.local", in: profiles))
    }

    func testSingleLabelHostIsRejected() {
        let profiles = [profile("P", ["*.firmaadi.com"])]
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "localhost", in: profiles))
    }

    func testIPAddressIsRejected() {
        let profiles = [profile("P", ["*.firmaadi.com"])]
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "10.0.0.7", in: profiles))
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "fe80::1", in: profiles))
    }

    func testBarePublicSuffixIsRejected() {
        let profiles = [profile("P", ["*.firmaadi.com"])]
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "com.tr", in: profiles))
    }

    func testNoProfilesMeansNoSuggestion() {
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "api.firmaadi.local", in: []))
    }

    func testInvalidPatternIsIgnored() {
        // Tek başına "*" geçersiz; öneri üretmemeli.
        let profiles = [profile("P", ["*"])]
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "api.firmaadi.local", in: profiles))
    }

    func testEmptyHost() {
        let profiles = [profile("P", ["*.firmaadi.com"])]
        XCTAssertNil(TLSPatternSuggestion.suggestion(for: "   ", in: profiles))
    }

    func testTrailingDotAndCaseAreNormalized() {
        let profiles = [profile("P", ["*.FirmaAdi.com"])]
        let match = TLSPatternSuggestion.suggestion(for: "API.FirmaAdi.local.", in: profiles)
        XCTAssertEqual(match?.hostToAdd, "api.firmaadi.local")
    }
}
