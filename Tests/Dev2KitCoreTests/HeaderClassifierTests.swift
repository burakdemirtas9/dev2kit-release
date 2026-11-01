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

    /// Güvenlik taraması S3: `key`, `credential`, `api_key` adları.
    func testKeyAndCredentialNamesAreCredentials() {
        let opaque = "SYNTHETICabcdef0123456789"
        for name in ["Ocp-Apim-Subscription-Key", "x-functions-key", "X-Access-Key", "X-Api_Key", "X-Partner-Credential"] {
            XCTAssertEqual(kind(name, opaque), .credential, name)
        }
        XCTAssertNil(kind("X-Access-Key", "kısa"), "değer yine opak olmalı")
    }

    /// Yeniden tarama: `key`/`auth` alt dizgi olarak eşleşince gizli olmayan
    /// başlıklar kimlik sayılıyordu. Ad parçalarına bakılır.
    func testKeyAndAuthMatchNamePartsNotSubstrings() {
        let opaque = "SYNTHETICabcdef0123456789"
        XCTAssertNil(kind("X-Cache-Key", "/api/v1/users/list/page"))
        XCTAssertNil(kind("X-Public-Key", opaque))
        XCTAssertNil(kind("X-Key-Id", opaque))
        XCTAssertNil(kind("X-Author", "burak-demirtas-1234567"))
        XCTAssertEqual(kind("X-Upstream-Authorization", opaque), .credential)
        XCTAssertEqual(kind("X-OAuth", opaque), .credential)
        XCTAssertEqual(kind("X-Secretkey", "kısa"), .credential, "secret adında değer kısa da olsa gizli")
        XCTAssertEqual(kind("X-Partner-ApiKey", opaque), .credential)
    }

    /// Kontrol: tekrar anahtarları gizli değil, isteği yinelemek için gerekir.
    func testIdempotencyKeysStayNormal() {
        XCTAssertNil(kind("Idempotency-Key", "8e03978e-40d5-43e8-bc93-6894a57f9324"))
        XCTAssertNil(kind("X-Idempotency-Key", "8e03978e-40d5-43e8-bc93-6894a57f9324"))
    }

    /// Kontrol: eski istisnalar yerinde.
    func testDescriptiveValuesStayNormal() {
        XCTAssertNil(kind("x-token-type", "Bearer"))
        XCTAssertNil(kind("x-token-issued-at", "2026-01-01T10:00:00.000Z"))
        XCTAssertNil(kind("X-Auth", "Bearer abc"), "şemadan sonrası opak değil")
        XCTAssertNil(kind("X-Password", "   "), "boş değer kimlik bilgisi değil")
    }
}
