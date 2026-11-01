import XCTest
@testable import Dev2KitCore

/// Güvenlik taraması S2: adında parola/secret geçen başlık, değeri kısa ya
/// da boşluklu olsa da kimlik bilgisidir. Değerler sentetiktir.
final class HeaderClassifierTests: XCTestCase {
    private func kind(_ name: String, _ value: String) -> ClassifiedHeader.SensitiveKind? {
        HeaderClassifier.classify(name: name, value: value).sensitiveKind
    }

    func testShortPasswordsAndSecretsAreCredentials() {
        XCTAssertEqual(kind("X-Password", "Pa$$w0rd"), .credential)
        XCTAssertEqual(kind("x-db-passwd", "kısa parola"), .credential)
        XCTAssertEqual(kind("X-Client-Secret", "abc"), .credential)
    }

    func testSchemePrefixedTokenIsCredential() {
        XCTAssertEqual(kind("X-Auth", "Bearer SYNTHETICabcdefghijklmnop"), .credential)
        XCTAssertEqual(kind("X-Upstream-Token", "token SYNTHETICabcdefghijklmnop"), .credential)
    }

    /// Kontrol: eski istisnalar yerinde.
    func testDescriptiveValuesStayNormal() {
        XCTAssertNil(kind("x-token-type", "Bearer"))
        XCTAssertNil(kind("x-token-issued-at", "2026-01-01T10:00:00.000Z"))
        XCTAssertNil(kind("X-Auth", "Bearer abc"), "şemadan sonrası opak değil")
        XCTAssertNil(kind("X-Password", "   "), "boş değer kimlik bilgisi değil")
    }
}
