import XCTest
@testable import Dev2KitCore

/// Güvenlik incelemesi (2026-10-21): yetkilendirme adresi yalnızca şema ve host
/// varlığına bakılarak `NSWorkspace.open`'a veriliyordu. İçe aktarılan bir
/// dev2kit koleksiyonundaki OAuth2 ayarı `file://`, `smb://` ya da başka bir
/// uygulamanın URL şemasını "Yetkilendir" tıklamasıyla açtırabiliyordu.
final class OAuthAuthorizationURLTests: XCTestCase {
    private func url(_ address: String) throws -> URL {
        try OAuth2Client.authorizationURL(
            config: OAuth2Config(authorizationURL: address, tokenURL: "https://idp.example.test/token", clientID: "client"),
            pkce: PKCE.generate(), state: "s", redirectURI: "http://127.0.0.1:1/callback"
        )
    }

    func testOnlyWebAddressesAreOpened() {
        for address in [
            "file://localhost/System/Applications/Calculator.app",
            "smb://attacker.example.test/share",
            "vnc://attacker.example.test",
            "someapp://host/action?run=1",
            "ftp://attacker.example.test/x",
            "http://idp.example.test/authorize",
        ] {
            XCTAssertThrowsError(try url(address), address)
        }
    }

    func testHTTPSAndLoopbackStillWork() throws {
        XCTAssertEqual(try url("https://idp.example.test/authorize").host, "idp.example.test")
        XCTAssertEqual(try url("http://localhost:8080/authorize").host, "localhost")
        XCTAssertEqual(try url("http://127.0.0.1:8080/authorize").host, "127.0.0.1")
        XCTAssertEqual(try url("HTTPS://IDP.example.test/authorize").scheme?.lowercased(), "https")
    }

    /// Token adresinde host `localhost` ise şemaya bakılmıyordu.
    func testTokenAddressMustBeWebToo() {
        for address in ["file://localhost/etc/hosts", "ftp://127.0.0.1/token", "http://idp.example.test/token"] {
            let config = OAuth2Config(authorizationURL: "https://idp.example.test/a", tokenURL: address, clientID: "client")
            XCTAssertThrowsError(try OAuth2Client.exchangeRequest(config: config, code: "c", verifier: "v",
                                                                 redirectURI: "http://127.0.0.1:1/callback", resolvedClientSecret: nil), address)
        }
        let local = OAuth2Config(authorizationURL: "https://idp.example.test/a", tokenURL: "http://localhost:9000/token", clientID: "client")
        XCTAssertNoThrow(try OAuth2Client.exchangeRequest(config: local, code: "c", verifier: "v",
                                                         redirectURI: "http://127.0.0.1:1/callback", resolvedClientSecret: nil))
    }
}
