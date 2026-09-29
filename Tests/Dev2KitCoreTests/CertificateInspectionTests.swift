import Security
import XCTest
@testable import Dev2KitCore

/// Güven deposuna KONULAN şeyin CA olup olmadığı ve sertifikanın hangi
/// adlar için geçerli olduğu.
///
/// Neden önemli: sahada en sık yapılan hata, CA yerine SUNUCU sertifikasını
/// güven deposuna koymak. Eskiden  bu durumda  dönüyordu (Basic
/// Constraints uzantısı olmayan sertifikada) ve arayüzdeki "CA değil" uyarısı
/// hiç çıkmıyordu — kullanıcı saatlerce yanlış yerde arıyordu. RFC 5280'e
/// göre bu uzantıyı taşımayan sertifika CA olamaz.
///
/// Fixture'lar bu test için üretildi: kendinden imzalı bir CA ve onun
/// imzaladığı, Basic Constraints taşımayan bir sunucu sertifikası.
final class CertificateInspectionTests: XCTestCase {
    private func certificate(_ base64: String) throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    private var caCertificate: SecCertificate { get throws { try certificate(Self.ca) } }
    private var leafCertificate: SecCertificate { get throws { try certificate(Self.leaf) } }

    // MARK: - CA tespiti

    func testCertificateAuthorityIsRecognised() throws {
        XCTAssertEqual(TrustStore.isCA(try caCertificate), true)
    }

    func testServerCertificateIsNotACertificateAuthority() throws {
        // Basic Constraints uzantısı yok -> CA değil. Eskiden  dönüyordu.
        XCTAssertEqual(TrustStore.isCA(try leafCertificate), false)
    }

    // MARK: - Geçerli adlar

    func testSubjectAlternativeNamesAreListed() throws {
        let names = CertificateLoader.subjectNames(of: try leafCertificate)
        XCTAssertEqual(names, ["ornek.test", "*.ornek.test", "10.0.0.1"])
    }

    func testCriticalFlagIsNotReportedAsAName() throws {
        let names = CertificateLoader.subjectNames(of: try leafCertificate)
        XCTAssertFalse(names.contains { $0.lowercased().contains("critical") }, "\(names)")
        XCTAssertFalse(names.contains("No"), "\(names)")
    }

    func testFallsBackToCommonNameWhenNoSAN() throws {
        // CA'nın SAN'ı yok; adı yine de gösterilebilmeli.
        XCTAssertEqual(CertificateLoader.subjectNames(of: try caCertificate), ["dev2kit Test CA"])
    }

    // MARK: - Fixture'lar

    private static let ca =
        "MIIBmzCCAUGgAwIBAgIUIEDk5a5SVk4bAQuc42HcGew2gjUwCgYIKoZIzj0EAwIwGjEYMBYGA1UE" +
        "AwwPZGV2MmtpdCBUZXN0IENBMCAXDTI2MDkyOTE5NDQxN1oYDzIxMjYwOTA1MTk0NDE3WjAaMRgw" +
        "FgYDVQQDDA9kZXYya2l0IFRlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATwziqUBd5a" +
        "a8qGUBHEoU4HBn3QXyV2YWB8DBMvtry1D102m5VC3F6D2UH7w06Uf72EEi2z23080AviCKkzFuvr" +
        "o2MwYTAdBgNVHQ4EFgQUF1bpviMLvrAEo3NX5AOcRQduH2IwHwYDVR0jBBgwFoAUF1bpviMLvrAE" +
        "o3NX5AOcRQduH2IwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwID" +
        "SAAwRQIgUxGRk/d4MjVjzsfUmdk42jqCiWwCAMO4CP9CIbMatBkCIQCsc0liF2FA57ESYnIYzr/E" +
        "/GbI9YtJ65/6mr9SGmmARg=="

    private static let leaf =
        "MIIBxDCCAWqgAwIBAgIULSDz97lFbj2J6cBT4vWo/nT8u4AwCgYIKoZIzj0EAwIwGjEYMBYGA1UE" +
        "AwwPZGV2MmtpdCBUZXN0IENBMCAXDTI2MDkyOTE5NDQxN1oYDzIxMjYwOTA1MTk0NDE3WjAVMRMw" +
        "EQYDVQQDDApvcm5lay50ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEKPj26sdKQrUZp/CP" +
        "F8zkboBukeyuljvYVF3SSUXTB/INZ4ZeiC/VBFDkcgn2/oGAr8/tYHQ9lDx5Y5DgPkvx9aOBkDCB" +
        "jTApBgNVHREEIjAgggpvcm5lay50ZXN0ggwqLm9ybmVrLnRlc3SHBAoAAAEwEwYDVR0lBAwwCgYI" +
        "KwYBBQUHAwEwCwYDVR0PBAQDAgWgMB0GA1UdDgQWBBRyvdRqRkL+5h5Ok5C7aR326hj6nTAfBgNV" +
        "HSMEGDAWgBQXVum+Iwu+sASjc1fkA5xFB24fYjAKBggqhkjOPQQDAgNIADBFAiBhVVLXQ6TIdMdv" +
        "5aOKtYTlFFDQ+YXctfZeYCMJoJgvJQIhAK2kaEfOg7MuVt0RX5H84mMI3XPPwzRg9c46Lp3XTB+H"
}
