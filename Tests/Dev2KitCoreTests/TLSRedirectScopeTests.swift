import Foundation
import Security
import XCTest
@testable import Dev2KitCore

/// Güvenlik incelemesi F4 (2026-10-20): host'a özel TLS profili (kurum CA'sı,
/// doğrulama tercihi, istemci kimliği) yönlendirme hedefine taşınmamalı.
/// Önceden ilk host'un profili zincirdeki her challenge'a veriliyordu.
///
/// Gerçek HTTPS sunucusu kurmak için kimliği anahtarlığa almak gerekirdi
/// (kullanıcının anahtarlığına dokunulmaz); bunun yerine yönlendirme
/// izleyicisine iki host'tan challenge verilir.
final class TLSRedirectScopeTests: XCTestCase {
    private func challenge(host: String, method: String = NSURLAuthenticationMethodServerTrust) throws -> URLAuthenticationChallenge {
        let data = try XCTUnwrap(Data(base64Encoded: CertificateInspectionTests.leaf))
        let leaf = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
        let space: URLProtectionSpace = method == NSURLAuthenticationMethodServerTrust
            ? FakeServerTrustSpace(host: host, trust: try XCTUnwrap(trust))
            : URLProtectionSpace(host: host, port: 443, protocol: "https", realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                          failureResponse: nil, error: nil, sender: NoopChallengeSender())
    }

    private func respond(_ tracker: RedirectTracker, to challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
        let task = URLSession.shared.dataTask(with: URL(string: "https://\(challenge.protectionSpace.host)")!)
        var result: URLSession.AuthChallengeDisposition?
        tracker.urlSession(URLSession.shared, task: task, didReceive: challenge) { disposition, _ in result = disposition }
        return result ?? .rejectProtectionSpace
    }

    /// A için "doğrulamayı atla" profili var, B için yok. B'nin challenge'ı
    /// A'nın profiliyle KABUL edilmemeli.
    func testRedirectTargetDoesNotInheritTheFirstHostsProfile() throws {
        let skipForA = ResolvedTLSProfile(caCertificates: [], pinToCA: false, skipValidation: true, identity: nil)
        var asked: [String] = []
        let tracker = RedirectTracker(policy: .default, credentialHeaders: [], hostPolicy: .notConfigured) { host in
            asked.append(host)
            return host == "a.test" ? skipForA : nil
        }
        XCTAssertEqual(respond(tracker, to: try challenge(host: "a.test")), .useCredential, "A kendi profiliyle kabul")
        XCTAssertNotEqual(respond(tracker, to: try challenge(host: "b.test")), .useCredential,
                          "B, A'nın profiliyle kabul edilmemeli")
        XCTAssertEqual(asked, ["a.test", "b.test"], "profil challenge'ı isteyen host için çözülür")
    }

    /// İstemci kimliği isteği de hedef host'un profiline göre: B'nin profili
    /// yoksa kimlik sunulmaz.
    func testClientIdentityIsLookedUpForTheChallengingHost() throws {
        var asked: [String] = []
        let tracker = RedirectTracker(policy: .default, credentialHeaders: [], hostPolicy: .notConfigured) { host in
            asked.append(host); return nil
        }
        let disposition = respond(tracker, to: try challenge(host: "b.test", method: NSURLAuthenticationMethodClientCertificate))
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertEqual(asked, ["b.test"])
    }

    func testProfileIsResolvedOncePerHost() throws {
        var calls = 0
        let tracker = RedirectTracker(policy: .default, credentialHeaders: [], hostPolicy: .notConfigured) { _ in
            calls += 1; return nil
        }
        _ = respond(tracker, to: try challenge(host: "a.test"))
        _ = respond(tracker, to: try challenge(host: "A.test"))
        XCTAssertEqual(calls, 1)
    }

    /// Hedefin profili yüklenemezse (CA dosyası yok) bağlantı reddedilir ve
    /// sebep kaydedilir; sessizce sistem güvenine düşülmez.
    func testUnloadableTargetProfileRejectsWithAReason() throws {
        struct Missing: LocalizedError { var errorDescription: String? { "CA dosyası yok" } }
        let tracker = RedirectTracker(policy: .default, credentialHeaders: [], hostPolicy: .notConfigured) { _ in throw Missing() }
        XCTAssertEqual(respond(tracker, to: try challenge(host: "b.test")), .cancelAuthenticationChallenge)
        XCTAssertEqual(tracker.rejection?.reason, "CA dosyası yok")
    }
}
