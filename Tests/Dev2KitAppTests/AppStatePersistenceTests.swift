import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kaydetme: gecikmeli yazım, anında yazım ve ikisinin yarışı.
/// Bu testlerin varlık sebebi `docs/UI-KURALLARI.md` 4b: geciken yazım,
/// sonradan yapılan yapısal değişikliğin üzerine ESKİ durumu yazarsa veri
/// sessizce kaybolur.
@MainActor
final class AppStatePersistenceTests: XCTestCase {
    private var harness: AppStateHarness!
    private var state: AppState { harness.state }

    override func setUp() {
        super.setUp()
        harness = AppStateHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
        super.tearDown()
    }

    func testStructuralChangeIsQueuedImmediatelyAndLandsOnDisk() throws {
        // `persist()` "hemen" demek: yazım hemen KUYRUĞA alınır. Diske inmesi
        // arka planda olur (WorkspaceSaver), çünkü encode + yazım MainActor'ı
        // tıkıyordu. Garanti şu: kuyruk seri ve kapanışta boşaltılıyor.
        let request = harness.addRequest(named: "hemen")
        state.waitForPendingWrites()

        let saved = try harness.store.load()
        XCTAssertTrue(
            saved.collections.flatMap(\.requests).contains { $0.id == request.id },
            "yapısal değişiklik kuyruk boşaltılınca diskte olmalı"
        )
    }

    func testTextEditIsDebouncedThenFlushed() throws {
        let request = harness.addRequest(named: "ad")
        var edited = request
        edited.url = "https://gecikmeli.example.com"
        state.selectedRequest?.wrappedValue = edited   // persistSoon

        let immediately = try harness.store.load()
        XCTAssertNotEqual(
            immediately.collections.flatMap(\.requests).first { $0.id == request.id }?.url,
            "https://gecikmeli.example.com",
            "metin düzenlemesi her tuşta diske yazılmamalı"
        )

        state.waitForPendingWrites()

        let flushed = try harness.store.load()
        XCTAssertEqual(
            flushed.collections.flatMap(\.requests).first { $0.id == request.id }?.url,
            "https://gecikmeli.example.com"
        )
    }

    func testPendingEditIsNotOverwrittenByLaterStructuralChange() throws {
        // Yarış senaryosu: yaz (gecikmeli) -> hemen ardından istek ekle (anında).
        // Geciken yazım eski durumu geri yazarsa yeni istek kaybolur.
        let request = harness.addRequest(named: "ilk")
        var edited = request
        edited.url = "https://yaziliyor.example.com"
        state.selectedRequest?.wrappedValue = edited

        harness.addRequest(named: "sonradan eklenen")

        let saved = try harness.savedWorkspace()
        let requests = saved.collections.flatMap(\.requests)
        XCTAssertEqual(requests.first { $0.id == request.id }?.url, "https://yaziliyor.example.com",
                       "gecikmeli düzenleme kaybolmamalı")
        XCTAssertTrue(requests.contains { $0.name == "sonradan eklenen" },
                      "yapısal değişiklik eski durumun altında kalmamalı")
    }

    func testWaitForPendingWritesIsSafeWhenNothingIsPending() throws {
        harness.addRequest(named: "a")
        state.waitForPendingWrites()
        state.waitForPendingWrites()   // kapanış yolunda iki kez çağrılabilir
        XCTAssertNoThrow(try harness.store.load())
    }

    func testDeleteSurvivesReload() throws {
        let a = harness.addRequest(named: "a")
        harness.addRequest(named: "b")
        state.deleteRequest(a.id)

        let saved = try harness.savedWorkspace()
        let names = saved.collections.flatMap(\.requests).map(\.name)
        XCTAssertFalse(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
    }
}
