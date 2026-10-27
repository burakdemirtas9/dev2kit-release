import XCTest
@testable import Dev2KitCore

/// Vault ekranı korumayı depoya göre anlatır; yalnızca Keychain güçlü sayılır.
/// Yalnızca tip bakılır: testler Keychain'e dokunmaz.
final class SecretStorageKindTests: XCTestCase {
    func testOnlyTheKeychainCountsAsKeychain() {
        XCTAssertEqual(SecretStorageKind(KeychainSecretStore()), .keychain)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-kind-\(UUID().uuidString)")
        XCTAssertEqual(SecretStorageKind(FileSecretStore(directory: directory)), .encryptedFile)
        XCTAssertEqual(SecretStorageKind(InMemorySecretStore()), .encryptedFile, "bilinmeyen depo fazla vaat etmez")
    }
}
