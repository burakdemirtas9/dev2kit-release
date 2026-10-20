import XCTest
@testable import Dev2KitCore

/// Mesaj türü kuralları: bilgi notu hata gibi görünmesin, başarı ile hata
/// aynı başlığı taşımasın.
final class ResultMessageTests: XCTestCase {
    /// Beklenen mesajlar Türkçe.
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    func testNoteWithoutMarkerIsInfo() {
        let line = MessageLine.note("32 Java dosyası okundu (derlenmedi, çalıştırılmadı): 15 Feign çağrısı bulundu.")
        XCTAssertEqual(line.kind, .info)
        XCTAssertFalse(line.text.contains("⚠"))
    }

    func testMarkedNoteIsWarningWithoutMarker() {
        let line = MessageLine.note("⚠︎ Doküman a.test adresinden alındı ama istekler b.test adresine gidecek.")
        XCTAssertEqual(line.kind, .warning)
        XCTAssertEqual(line.text, "Doküman a.test adresinden alındı ama istekler b.test adresine gidecek.")
    }

    func testMarkerWithoutVariationSelectorIsAlsoWarning() {
        XCTAssertEqual(MessageLine.note("⚠ Dikkat").kind, .warning)
        XCTAssertEqual(MessageLine.note("⚠ Dikkat").text, "Dikkat")
    }

    private func item(_ name: String = "Örnek", imported: Int = 3, blocked: Int = 0, renamed: Bool = false, notes: [String] = []) -> ImportResult.Item {
        ImportResult.Item(name: name, importedCount: imported, blockedCount: blocked, wasRenamed: renamed, notes: notes)
    }

    /// Referans durum (2026-10-20): yalnızca bilgi notu olan aktarma başarıdır.
    func testInfoNotesKeepSuccess() {
        let message = ImportResult.message(for: [item(imported: 18, notes: ["32 Java dosyası okundu."])])
        XCTAssertEqual(message.kind, .success)
        XCTAssertEqual(message.title, "İçe aktarıldı")
        XCTAssertEqual(message.message, "“Örnek” · 18 request")
        XCTAssertEqual(message.lines, [MessageLine(.info, "32 Java dosyası okundu.")])
    }

    func testBlockedRequestsMakeWarning() {
        let message = ImportResult.message(for: [item(imported: 40, blocked: 2)])
        XCTAssertEqual(message.kind, .warning)
        XCTAssertEqual(message.title, "İçe aktarıldı, 2 request dışarıda kaldı")
        XCTAssertEqual(message.lines.first?.kind, .warning)
    }

    func testWarningNoteMakesWarning() {
        let message = ImportResult.message(for: [item(notes: ["⚠︎ Başka host"])])
        XCTAssertEqual(message.kind, .warning)
        XCTAssertEqual(message.title, "İçe aktarıldı, kontrol edilecekler var")
    }

    func testRenameIsInfo() {
        let message = ImportResult.message(for: [item(renamed: true)])
        XCTAssertEqual(message.kind, .success)
        XCTAssertEqual(message.lines.first?.kind, .info)
    }

    func testNothingImportedIsError() {
        let message = ImportResult.message(for: [item(imported: 0, blocked: 5)])
        XCTAssertEqual(message.kind, .error)
        XCTAssertEqual(message.title, "İçe aktarılamadı")
    }

    func testMultipleCollectionsAreCountedAndPrefixed() {
        let message = ImportResult.message(for: [item("A", imported: 2), item("B", imported: 0, blocked: 1)])
        XCTAssertEqual(message.kind, .warning)
        XCTAssertEqual(message.message, "“A” · 2 request")
        XCTAssertTrue(message.lines.contains(MessageLine(.error, "“B”: Aktarılmadı; tüm request'ler güvenlik nedeniyle engellendi.")))
    }

    func testPlainTextJoinsEverything() {
        let message = ResultMessage(kind: .success, title: "T", message: "M", lines: [MessageLine(.info, "L")])
        XCTAssertEqual(message.plainText, "T\nM\nL")
    }
}
