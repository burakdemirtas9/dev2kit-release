import XCTest
@testable import Dev2KitCore

final class NetworkInfoTests: XCTestCase {
    // MARK: - Ham değerlerin karşılığı

    func testKnownTLSVersions() {
        XCTAssertEqual(NetworkInfo.tlsProtocolName(0x0303), "TLS 1.2")
        XCTAssertEqual(NetworkInfo.tlsProtocolName(0x0304), "TLS 1.3")
    }

    func testUnknownTLSVersionIsShownRaw() {
        // Yanlış isim vermektense ham değeri göster.
        XCTAssertEqual(NetworkInfo.tlsProtocolName(0x0999), "0x0999")
    }

    func testKnownCipherSuites() {
        XCTAssertEqual(NetworkInfo.cipherName(0x1301), "TLS_AES_128_GCM_SHA256")
        XCTAssertEqual(NetworkInfo.cipherName(0xC02F), "ECDHE_RSA_AES_128_GCM_SHA256")
    }

    func testUnknownCipherIsShownRaw() {
        XCTAssertEqual(NetworkInfo.cipherName(0xABCD), "0xABCD")
    }

    // MARK: - Adres biçimi

    func testAddressJoinsHostAndPort() {
        XCTAssertEqual(NetworkInfo.address(host: "192.168.1.108", port: 52341), "192.168.1.108:52341")
    }

    func testAddressWithoutPortIsJustHost() {
        XCTAssertEqual(NetworkInfo.address(host: "10.0.0.1", port: nil), "10.0.0.1")
        XCTAssertEqual(NetworkInfo.address(host: "10.0.0.1", port: 0), "10.0.0.1")
    }

    func testAddressWithoutHostIsNil() {
        XCTAssertNil(NetworkInfo.address(host: nil, port: 443))
        XCTAssertNil(NetworkInfo.address(host: "", port: 443))
    }

    // MARK: - Boşluk

    func testEmptyInfoIsReportedEmpty() {
        // Gösterilecek hiçbir şey yoksa arayüz düğmeyi açmamalı.
        XCTAssertTrue(NetworkInfo().isEmpty)
        XCTAssertFalse(NetworkInfo(httpVersion: "h2").isEmpty)
    }

    // MARK: - Sertifika

    func testExpiryCheck() {
        let past = CertificateSummary(commonName: "a", issuerCommonName: "b",
                                      validUntil: Date(timeIntervalSinceNow: -60))
        let future = CertificateSummary(commonName: "a", issuerCommonName: "b",
                                        validUntil: Date(timeIntervalSinceNow: 60))
        let unknown = CertificateSummary(commonName: "a", issuerCommonName: "b", validUntil: nil)
        XCTAssertTrue(past.isExpired())
        XCTAssertFalse(future.isExpired())
        XCTAssertFalse(unknown.isExpired(), "tarih bilinmiyorsa 'süresi geçmiş' denmez")
    }

    func testResponseWithoutMetricsHasNoNetworkInfo() {
        let response = ResponseData(statusCode: 200, headers: [], body: Data(),
                                    duration: 0.1, finalURL: nil)
        XCTAssertNil(response.network, "künye yoksa alan boş kalmalı, uydurulmamalı")
    }
}
