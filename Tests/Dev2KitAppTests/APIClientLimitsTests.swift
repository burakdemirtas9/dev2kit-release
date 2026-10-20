import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// API Client editörleri Workbench kapısına bağlandı (2026-10-18): yanıt
/// Workbench çıktısı gibi (20 MB, 1 MB'tan uzun satır yok), gövde Workbench
/// girdisi gibi (4 MB, 16.000 satır, 1 MB satır). Mesajlar Türkçe.
@MainActor
final class APIClientLimitsTests: XCTestCase {
    private func response(_ text: String, contentType: String) -> ResponseData {
        ResponseData(statusCode: 200, headers: [("Content-Type", contentType)], body: Data(text.utf8), duration: 0, finalURL: nil)
    }

    private func singleLine(bytes: Int) -> String {
        String(repeating: "abcdefghij", count: bytes / 10 + 1)
    }

    func testLongSingleLinePlainResponseIsNotShownInTheEditor() {
        let display = AppState.makeDisplay(response(singleLine(bytes: 1_500_000), contentType: "text/plain"))
        XCTAssertFalse(display.fitsEditor)
    }

    func testMinifiedJSONResponseIsFormattedAndShown() {
        let row = #"{"id":1,"ad":"Müşteri"},"#
        let json = "[" + String(repeating: row, count: 1_500_000 / row.utf8.count) + "1]"
        let display = AppState.makeDisplay(response(json, contentType: "application/json"))
        XCTAssertTrue(display.fitsEditor, "biçimlenince satırlar kısa: gösterilir")
    }

    func testBrokenMinifiedJSONResponseIsNotShown() {
        let json = "[" + String(repeating: #"{"id":1},"#, count: 200_000) // kapanmamış: biçimlenemez, tek satır
        XCTAssertFalse(AppState.makeDisplay(response(json, contentType: "application/json")).fitsEditor)
    }

    func testSmallResponsesFit() {
        XCTAssertTrue(AppState.makeDisplay(response(#"{"a":1}"#, contentType: "application/json")).fitsEditor)
        XCTAssertTrue(AppState.makeDisplay(response("", contentType: "text/plain")).fitsEditor)
    }

    /// Mesaj seçili dilde (L10n); sayılar dile göre gruplanır.
    func testRejectionMessagesFollowTheLanguage() {
        let saved = Localizer.shared.language
        defer { Localizer.shared.language = saved }
        Localizer.shared.language = .turkish
        XCTAssertEqual(WorkbenchLimits.Rejection.tooManyLines(16_001).localized, "Eklenmedi: sonuç 16.001 satır olurdu. Girdi başına sınır 16.000 satır.")
        XCTAssertEqual(WorkbenchLimits.Rejection.atLineLimit.localized, "Eklenmedi: girdi 16.000 satır sınırında. Önce bir şey sil.")
        Localizer.shared.language = .english
        XCTAssertEqual(WorkbenchLimits.Rejection.tooManyLines(16_001).localized, "Not added: the result would have 16,001 lines. The limit is 16,000 lines per input.")
        XCTAssertEqual(WorkbenchLimits.Rejection.atLineLimit.localized, WorkbenchLimits.atLineLimitMessage)
    }
}
