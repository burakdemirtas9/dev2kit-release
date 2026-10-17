import Foundation
import Security
import XCTest
@testable import Dev2KitCore

/// Güven ayarı değişince havuzdaki bağlantılar bırakılmalı.
///
/// Sahadaki vaka: CA güven deposundan kaldırıldıktan sonra istekler gitmeye
/// devam ediyordu, uygulama kapatılıp açılınca hata geliyordu. Sebep:
/// sertifika yalnızca el sıkışmada doğrulanıyor, havuzdaki bağlantı eski
/// kararla yaşıyordu. Yerel keep-alive sunucusuyla ölçüldü: düzeltmeden önce
/// CA kaldırıldıktan sonraki istek `isReusedConnection == true` ile geçiyor,
/// sonra reddediliyor.
///
/// Bağlantı havuzu doğrudan gözlenemediği için burada oturumun yenilenip
/// yenilenmediği test ediliyor; havuz oturuma ait.
final class PooledConnectionTests: XCTestCase {
    private let scope = RequestEngine.Scope(environmentID: nil)

    private func certificate() throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: CertificateInspectionTests.ca))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    private func cookie() throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .name: "oturum", .value: "abc", .domain: "api.firma.local", .path: "/",
        ]))
    }

    func testTrustStoreChangeRenewsSession() throws {
        let engine = RequestEngine()
        let before = engine.session(for: scope)
        engine.trustStoreCertificates = [try certificate()]
        XCTAssertFalse(before === engine.session(for: scope))
    }

    func testProfileChangeRenewsSession() {
        let engine = RequestEngine()
        let before = engine.session(for: scope)
        engine.tlsProfiles = [TLSProfile(hostPatterns: ["api.firma.local"])]
        XCTAssertFalse(before === engine.session(for: scope))
    }

    func testLongValidityChangeRenewsSession() {
        let engine = RequestEngine()
        let before = engine.session(for: scope)
        engine.trustStoreAllowsLongValidity = true
        XCTAssertFalse(before === engine.session(for: scope))
    }

    func testUnchangedAssignmentKeepsSession() throws {
        // TLS ekranı her açılışta depoyu yeniden yüklüyor; aynı içerik
        // bağlantıları koparmamalı. Yeni nesne, aynı DER: değişiklik değil.
        let engine = RequestEngine()
        engine.trustStoreCertificates = [try certificate()]
        let before = engine.session(for: scope)
        engine.trustStoreCertificates = [try certificate()]
        engine.trustStoreAllowsLongValidity = false
        engine.tlsProfiles = []
        XCTAssertTrue(before === engine.session(for: scope))
    }

    func testCookiesSurviveRenewal() throws {
        // Güven ayarı değiştirmek oturum girişlerini silmemeli.
        let engine = RequestEngine()
        engine.session(for: scope).configuration.httpCookieStorage?.setCookie(try cookie())
        engine.trustStoreCertificates = [try certificate()]
        XCTAssertEqual(engine.cookies(in: scope).map(\.value), ["abc"])
    }
}
