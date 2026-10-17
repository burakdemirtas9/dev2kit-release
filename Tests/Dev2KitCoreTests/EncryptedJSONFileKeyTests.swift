import XCTest
@testable import Dev2KitCore

/// Şifreleme anahtarı okunamayınca yenisi ÜRETİLMEZ: eskisinin üzerine
/// yazılan anahtar vault'u ve geçmişi kalıcı olarak açılmaz hale getirirdi.
final class EncryptedJSONFileKeyTests: XCTestCase {
    private var directory: URL!
    private var dataURL: URL { directory.appendingPathComponent("secrets.enc") }
    private var keyURL: URL { directory.appendingPathComponent(".secrets.key") }
    private var file: EncryptedJSONFile<[String: String]> { EncryptedJSONFile(fileURL: dataURL, keyURL: keyURL) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-key-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testFirstSaveCreatesAPrivateKeyAndRoundTrips() throws {
        try file.save(["api": "değer"])
        XCTAssertEqual(try file.load(fallback: [:]), ["api": "değer"])
        XCTAssertEqual(try permissions(keyURL), 0o600)
        XCTAssertEqual(try Data(contentsOf: keyURL).count, 32)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "geçici anahtar dosyası kalmamalı")
    }

    func testUnreadableKeyIsNotReplaced() throws {
        try file.save(["api": "değer"])
        let key = try Data(contentsOf: keyURL)
        let sealed = try Data(contentsOf: dataURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keyURL.path)

        XCTAssertThrowsError(try file.load(fallback: [:])) { error in
            XCTAssertEqual(error as? EncryptedJSONFile<[String: String]>.FileError, .keyUnreadable(path: keyURL.path))
        }
        XCTAssertThrowsError(try file.save(["yeni": "x"]), "yeni anahtarla üzerine yazılmamalı")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        XCTAssertEqual(try Data(contentsOf: keyURL), key, "anahtar değişmemeli")
        XCTAssertEqual(try Data(contentsOf: dataURL), sealed, "şifreli veri değişmemeli")
        // İzin düzelince eski veri yine açılır.
        XCTAssertEqual(try file.load(fallback: [:]), ["api": "değer"])
    }

    func testDamagedKeyIsNotReplaced() throws {
        try file.save(["api": "değer"])
        try Data("kısa".utf8).write(to: keyURL)
        XCTAssertThrowsError(try file.load(fallback: [:]))
        XCTAssertThrowsError(try file.save(["yeni": "x"]))
        XCTAssertEqual(try Data(contentsOf: keyURL), Data("kısa".utf8))
    }

    func testMissingKeyWithExistingDataIsAnErrorNotANewKey() throws {
        try file.save(["api": "değer"])
        try FileManager.default.removeItem(at: keyURL)
        let sealed = try Data(contentsOf: dataURL)

        XCTAssertThrowsError(try file.save(["yeni": "x"])) { error in
            XCTAssertEqual(error as? EncryptedJSONFile<[String: String]>.FileError, .keyMissing(path: keyURL.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path), "yeni anahtar üretilmemeli")
        XCTAssertEqual(try Data(contentsOf: dataURL), sealed)
    }

    func testNothingOnDiskStillLoadsTheFallback() throws {
        XCTAssertEqual(try file.load(fallback: ["boş": ""]), ["boş": ""])
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path), "okumak anahtar üretmemeli")
    }
}
