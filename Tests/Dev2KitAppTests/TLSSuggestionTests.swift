import Foundation
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Öneri kabul edilince NE oluyor: kalıcı mı, tekrarlıyor mu.
/// Kuralın kendisi Core'da testli (`TLSPatternSuggestionTests`); burada
/// durumun ve kalıcılığın davranışı ölçülüyor.
@MainActor
final class TLSSuggestionTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }

    override func setUp() {
        super.setUp()
        harness = AppStateHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
        super.tearDown()
    }

    @discardableResult
    private func addProfile(clientCertificate: Bool = false) -> UUID {
        let id = state.addTLSProfile()
        let index = state.workspace.tlsProfiles.firstIndex { $0.id == id }!
        state.workspace.tlsProfiles[index].name = "İç Servisler"
        state.workspace.tlsProfiles[index].hostPatterns = ["*.firmaadi.com"]
        state.workspace.tlsProfiles[index].caCertificatePath = "/tmp/ca.pem"
        if clientCertificate {
            state.workspace.tlsProfiles[index].clientCertificatePath = "/tmp/kimlik.p12"
        }
        return id
    }

    private func tlsError(host: String) -> URLError {
        URLError(
            .serverCertificateUntrusted,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://\(host)/x")!]
        )
    }

    // MARK: - Teklif

    func testTLSFailureOffersSuggestion() {
        addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        XCTAssertEqual(state.tlsSuggestion?.hostToAdd, "api.firmaadi.local")
        XCTAssertEqual(state.tlsSuggestion?.matchedPattern, "*.firmaadi.com")
    }

    func testNonTLSErrorDoesNotOffer() {
        addProfile()
        state.offerTLSSuggestion(for: URLError(.timedOut))
        XCTAssertNil(state.tlsSuggestion)
    }

    func testHostThatAlreadyMatchesDoesNotOffer() {
        addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.com"))
        XCTAssertNil(state.tlsSuggestion)
    }

    func testUnrelatedHostDoesNotOffer() {
        addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.baskafirma.local"))
        XCTAssertNil(state.tlsSuggestion)
    }

    func testClientCertificateIsReportedToUI() {
        addProfile(clientCertificate: true)
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        XCTAssertTrue(state.tlsSuggestion?.carriesClientCertificate == true)
        XCTAssertTrue(state.tlsSuggestion?.isNonPublicSuffix == true)
    }

    // MARK: - Kabul: kalıcı ve tekrarsız

    func testAcceptWritesExactHostToProfile() {
        let id = addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        state.acceptTLSSuggestion()

        let profile = state.workspace.tlsProfiles.first { $0.id == id }!
        XCTAssertEqual(profile.hostPatterns, ["*.firmaadi.com", "api.firmaadi.local"])
        XCTAssertNil(state.tlsSuggestion)
    }

    func testAcceptNeverAddsWildcard() {
        addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        state.acceptTLSSuggestion()
        let patterns = state.workspace.tlsProfiles[0].hostPatterns
        XCTAssertFalse(patterns.contains { $0.hasPrefix("*.firmaadi.local") }, "\(patterns)")
    }

    func testAcceptedHostIsNotOfferedAgain() {
        addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        state.acceptTLSSuggestion()
        // Artık eşleşiyor: aynı hata gelse bile teklif çıkmamalı.
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        XCTAssertNil(state.tlsSuggestion)
    }

    func testAcceptSurvivesReload() throws {
        addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        state.acceptTLSSuggestion()
        state.waitForPendingWrites()

        let reloaded = try harness.store.load()
        XCTAssertEqual(reloaded.tlsProfiles.first?.hostPatterns.last, "api.firmaadi.local")
    }

    func testAcceptDoesNotDuplicate() {
        addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        state.acceptTLSSuggestion()
        // Elle aynı öneriyi tekrar kurup kabul etsek bile ikinci kez eklenmez.
        state.tlsSuggestion = TLSPatternSuggestion.Match(
            profileID: state.workspace.tlsProfiles[0].id,
            profileName: "İç Servisler",
            hostToAdd: "api.firmaadi.local",
            matchedPattern: "*.firmaadi.com",
            carriesClientCertificate: false,
            isNonPublicSuffix: true
        )
        state.acceptTLSSuggestion()
        XCTAssertEqual(state.workspace.tlsProfiles[0].hostPatterns.count, 2)
    }

    // MARK: - Ret: oturumluk, kalıcı değil

    func testDeclineSilencesHostForThisSession() {
        addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        state.declineTLSSuggestion()
        XCTAssertNil(state.tlsSuggestion)

        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        XCTAssertNil(state.tlsSuggestion, "reddedilen host tekrar sorulmamalı")
    }

    func testDeclineDoesNotSilenceOtherHosts() {
        addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        state.declineTLSSuggestion()
        state.offerTLSSuggestion(for: tlsError(host: "web.firmaadi.local"))
        XCTAssertEqual(state.tlsSuggestion?.hostToAdd, "web.firmaadi.local")
    }

    func testDeclineIsNotPersisted() throws {
        addProfile()
        state.offerTLSSuggestion(for: tlsError(host: "api.firmaadi.local"))
        state.declineTLSSuggestion()
        state.waitForPendingWrites()

        // Diske yazılan workspace'te reddin izi olmamalı.
        let data = try Data(contentsOf: harness.directory.appendingPathComponent("workspace.json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("api.firmaadi.local"), "ret kalıcı kaydedilmiş")
    }
}
