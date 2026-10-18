import XCTest
@testable import Dev2KitCore

final class ImportFileTests: XCTestCase {
    /// Sıkıştırmasız (stored) küçük ZIP: test için. CRC okuyucuda denetlenmiyor.
    private func zip(_ files: [(String, Data)], declaredSize: ((String) -> UInt32?)? = nil) -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: Int, into data: inout Data) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32, into data: inout Data) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        for (name, content) in files {
            let offset = UInt32(out.count)
            let size = declaredSize?(name) ?? UInt32(content.count)
            let nameData = Data(name.utf8)
            u32(0x0403_4B50, into: &out)
            for value in [20, 0, 0, 0, 0] { u16(value, into: &out) }
            u32(0, into: &out)
            u32(UInt32(content.count), into: &out)
            u32(UInt32(content.count), into: &out)
            u16(nameData.count, into: &out)
            u16(0, into: &out)
            out.append(nameData)
            out.append(content)

            u32(0x0201_4B50, into: &central)
            for value in [20, 20, 0, 0, 0, 0] { u16(value, into: &central) }
            u32(0, into: &central)
            u32(UInt32(content.count), into: &central)
            u32(size, into: &central)
            u16(nameData.count, into: &central)
            for value in [0, 0, 0, 0] { u16(value, into: &central) }
            u32(0, into: &central)
            u32(offset, into: &central)
            central.append(nameData)
        }
        let directoryOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, into: &out)
        for value in [0, 0, files.count, files.count] { u16(value, into: &out) }
        u32(UInt32(central.count), into: &out)
        u32(directoryOffset, into: &out)
        u16(0, into: &out)
        return out
    }

    func testDetectsTypesByContentNotExtension() {
        XCTAssertEqual(try ImportFile.kind(of: Data("%PDF-1.7\n...".utf8)).get(), .pdf)
        XCTAssertEqual(try ImportFile.kind(of: Data("curl https://a.example.com".utf8)).get(), .text)
        func rejection(_ bytes: [UInt8]) -> String? {
            if case .failure(let r) = ImportFile.kind(of: Data(bytes)) { return r.message }
            return nil
        }
        XCTAssertEqual(rejection([0xCF, 0xFA, 0xED, 0xFE, 7, 0, 0, 1]), "Çalıştırılabilir dosya; içe aktarılmaz.")
        XCTAssertEqual(rejection([0x4D, 0x5A, 0x90, 0]), "Çalıştırılabilir dosya; içe aktarılmaz.")
        XCTAssertEqual(rejection([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]), "Resim dosyası; içinden istek çıkarılamaz.")
        XCTAssertTrue(rejection([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])?.contains(".docx") == true)
        XCTAssertNotNil(rejection([0x00, 0x01, 0x02, 0xFF]), "ikili veri metin sayılmaz")
        XCTAssertNotNil(rejection([]))
    }

    func testRealWordDocumentFromTextutil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-docx-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("api.txt")
        try "API dokümanı\nÖrnek istek:\ncurl -X POST https://api.example.com/v1/orders -H \"Content-Type: application/json\"\nSon.".write(to: source, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "docx", source.path, "-output", dir.appendingPathComponent("api.docx").path]
        try process.run()
        process.waitUntilExit()
        let data = try Data(contentsOf: dir.appendingPathComponent("api.docx"))

        XCTAssertEqual(try ImportFile.kind(of: data).get(), .word)
        let text = try ImportFile.text(of: data, kind: .word)
        XCTAssertEqual(AutoImport.scan(text).curl.map(\.request.name), ["POST /v1/orders"], text)
    }

    func testExcelSharedStrings() throws {
        let strings = #"<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Endpoint</t></si><si><t>curl https://api.example.com/v1/users -H "Accept: application/json"</t></si><si><r><t>curl -X DELETE </t></r><r><t>https://api.example.com/v1/users/7</t></r></si></sst>"#
        let data = zip([("[Content_Types].xml", Data("<x/>".utf8)), ("xl/workbook.xml", Data("<workbook/>".utf8)), ("xl/sharedStrings.xml", Data(strings.utf8))])
        XCTAssertEqual(try ImportFile.kind(of: data).get(), .excel)
        XCTAssertEqual(AutoImport.scan(try ImportFile.text(of: data, kind: .excel)).curl.map(\.request.name), ["GET /v1/users", "DELETE /v1/users/7"])
    }

    func testZipBombIsRejectedBeforeExtracting() {
        let bomb = zip([("word/document.xml", Data("<w/>".utf8))], declaredSize: { _ in 1_000_000_000 })
        guard case .failure(let rejection) = ImportFile.kind(of: bomb) else { return XCTFail() }
        XCTAssertTrue(rejection.message.contains("zip bombası"))
        XCTAssertThrowsError(try ZipReader(bomb))
    }

    func testOtherArchivesAreRejected() {
        guard case .failure(let rejection) = ImportFile.kind(of: zip([("a.txt", Data("x".utf8))])) else { return XCTFail() }
        XCTAssertTrue(rejection.message.contains("ZIP arşivi"))
    }

    func testOfficeXMLDoesNotResolveExternalEntities() throws {
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-office-xxe-\(UUID()).txt")
        try "GIZLI-OFFICE".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        let xml = "<!DOCTYPE d [<!ENTITY x SYSTEM \"\(secret.absoluteString)\">]><w:document xmlns:w=\"w\"><w:p><w:t>&x;</w:t></w:p></w:document>"
        let data = zip([("word/document.xml", Data(xml.utf8))])
        XCTAssertFalse(try ImportFile.text(of: data, kind: .word).contains("GIZLI-OFFICE"))
    }

    func testOversizedFileIsRejected() {
        guard case .failure(let rejection) = ImportFile.kind(of: Data(count: ImportFile.maxBytes + 1)) else { return XCTFail() }
        XCTAssertTrue(rejection.message.contains("çok büyük"))
    }
}
