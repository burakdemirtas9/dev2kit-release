import XCTest
@testable import Dev2KitCore

final class FileSecretStoreTests: XCTestCase {
    private var directory: URL!
    private var store: FileSecretStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev2kit-test-\(UUID().uuidString)")
        store = FileSecretStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSetAndGetRoundtrip() throws {
        try store.setSecret("gizli-değer", forName: "token")
        XCTAssertEqual(try store.secret(forName: "token"), "gizli-değer")
    }

    func testMissingSecretReturnsNil() throws {
        XCTAssertNil(try store.secret(forName: "yok"))
    }

    func testUpdateOverwrites() throws {
        try store.setSecret("eski", forName: "a")
        try store.setSecret("yeni", forName: "a")
        XCTAssertEqual(try store.secret(forName: "a"), "yeni")
    }

    func testDeleteAndList() throws {
        try store.setSecret("1", forName: "b")
        try store.setSecret("2", forName: "a")
        XCTAssertEqual(try store.listSecretNames(), ["a", "b"])
        try store.deleteSecret(forName: "a")
        XCTAssertEqual(try store.listSecretNames(), ["b"])
    }

    func testFileIsEncryptedOnDisk() throws {
        try store.setSecret("cok-gizli-deger", forName: "token")
        let raw = try Data(contentsOf: directory.appendingPathComponent("secrets.enc"))
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("cok-gizli-deger"), "secret diske düz metin yazılmamalı")
        XCTAssertFalse(text.contains("token"))
    }

    func testPersistsAcrossInstances() throws {
        try store.setSecret("kalici", forName: "x")
        let second = FileSecretStore(directory: directory)
        XCTAssertEqual(try second.secret(forName: "x"), "kalici")
    }
}
