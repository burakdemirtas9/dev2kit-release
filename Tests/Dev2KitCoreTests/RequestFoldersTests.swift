import XCTest
@testable import Dev2KitCore

/// Collection içi klasörler: istek üzerindeki yol, gösterim sırası, satırlar,
/// sürükle-bırak yerleşimi ve eski verilerle uyum.
final class RequestFoldersTests: XCTestCase {
    private func request(_ name: String, _ folder: [String] = []) -> RequestModel {
        RequestModel(name: name, url: "https://a.test/\(name)", folder: folder)
    }

    private let folderID: ([String]) -> UUID = { RequestFolders.rowID(collection: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, path: $0) }

    // MARK: Eski verilerle uyum

    /// Klasörsüz istek diske eskisiyle AYNI yazılır; `folder` alanı olmayan
    /// (eski) dosya açılır.
    func testFolderlessRequestEncodesWithoutTheFieldAndOldFilesDecode() throws {
        let plain = request("a")
        let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(text.contains("folder"), "mevcut dosyalar değişmez")
        XCTAssertEqual(try JSONDecoder().decode(RequestModel.self, from: Data(text.utf8)).folder, [])

        let placed = request("b", ["Kullanıcı", "Yönetim"])
        let again = try JSONDecoder().decode(RequestModel.self, from: JSONEncoder().encode(placed))
        XCTAssertEqual(again, placed)
    }

    /// Klasör tele çıkmaz: "son gönderilenden farklı" işaretini yakmaz.
    func testFolderIsNotAFunctionalField() {
        XCTAssertTrue(request("a", ["K"]).isFunctionallyEqual(to: request("a")))
    }

    func testPathIsSanitized() {
        XCTAssertEqual(RequestFolders.sanitized(["  A ", "", "B"]), ["A", "B"])
        XCTAssertEqual(RequestFolders.sanitized(Array(repeating: "k", count: 30)).count, RequestFolders.maxDepth)
        XCTAssertEqual(RequestFolders.sanitized([String(repeating: "k", count: 500)])[0].count, RequestFolders.maxNameLength + 1)
    }

    // MARK: Gösterim sırası

    func testFolderlessCollectionKeepsItsOrder() {
        let requests = [request("c"), request("a"), request("b")]
        XCTAssertEqual(RequestFolders.canonical(requests), requests)
    }

    /// Her düzeyde önce o düzeyin istekleri, sonra alt klasörler (ilk görülme sırasıyla).
    func testCanonicalGroupsFoldersAndKeepsRelativeOrder() {
        let requests = [request("u1", ["U"]), request("kök1"), request("s1", ["S"]), request("u2", ["U"]),
                        request("y1", ["U", "Y"]), request("kök2"), request("u3", ["U"])]
        XCTAssertEqual(RequestFolders.canonical(requests).map(\.name), ["kök1", "kök2", "u1", "u2", "u3", "y1", "s1"])
        XCTAssertEqual(RequestFolders.paths(in: requests), [["U"], ["U", "Y"], ["S"]])
    }

    // MARK: Klasör işlemleri

    func testRenameAndRemoveAffectTheWholeSubtree() {
        let requests = [request("a", ["U"]), request("b", ["U", "Y"]), request("c", ["S"]), request("d")]
        XCTAssertEqual(RequestFolders.renaming(["U"], to: " Üye ", in: requests).map(\.folder), [["Üye"], ["Üye", "Y"], ["S"], []])
        XCTAssertEqual(RequestFolders.renaming(["U"], to: "  ", in: requests), requests, "boş ad yok sayılır")
        XCTAssertEqual(RequestFolders.renaming(["U"], to: "S", in: requests).map(\.folder), [["S"], ["S", "Y"], ["S"], []], "aynı adla birleşir")
        XCTAssertEqual(RequestFolders.removing(["U"], in: requests).map(\.folder), [[], ["Y"], ["S"], []], "içindekiler bir üste çıkar")
    }

    func testPlacingMovesIntoFolderAndOrders() {
        let a = request("a"), b = request("b", ["K"]), c = request("c", ["K"]), d = request("d")
        let all = [a, b, c, d]
        XCTAssertEqual(RequestFolders.placing([d.id], in: ["K"], before: c.id, requests: all).map(\.name), ["a", "b", "d", "c"])
        XCTAssertEqual(RequestFolders.placing([a.id], in: ["K"], before: nil, requests: all).map(\.name), ["d", "b", "c", "a"], "çapa yoksa klasörün sonu")
        XCTAssertEqual(RequestFolders.placing([b.id], in: [], before: a.id, requests: all).map(\.name), ["b", "a", "d", "c"], "klasörden köke")
        XCTAssertEqual(RequestFolders.placing([a.id], in: ["K"], before: d.id, requests: all).map(\.name), ["d", "b", "c", "a"],
                       "başka klasördeki çapa yok sayılır")
        XCTAssertEqual(RequestFolders.placing([a.id, d.id], in: ["Yeni", "Alt"], before: nil, requests: all).map(\.folder),
                       [["K"], ["K"], ["Yeni", "Alt"], ["Yeni", "Alt"]])
    }

    // MARK: Satırlar

    func testRowsInsertFolderHeadersAndHideCollapsedSubtrees() {
        let k = request("kök"), u = request("u", ["U"]), y = request("y", ["U", "Y"]), s = request("s", ["S"])
        let requests = RequestFolders.canonical([u, k, s, y])
        let open = RequestTreeRows.rows(for: requests, expanded: [], collapsedFolders: [], folderID: folderID)
        XCTAssertEqual(open.map(\.id), [k.id, folderID(["U"]), u.id, folderID(["U", "Y"]), y.id, folderID(["S"]), s.id])
        if case .folder(_, let path, let count) = open[1] {
            XCTAssertEqual(path, ["U"]); XCTAssertEqual(count, 2, "alt klasördekiler dahil")
        } else { XCTFail("klasör satırı bekleniyordu") }

        let collapsed = RequestTreeRows.rows(for: requests, expanded: [], collapsedFolders: [folderID(["U"])], folderID: folderID)
        XCTAssertEqual(collapsed.map(\.id), [k.id, folderID(["U"]), folderID(["S"]), s.id], "katlı klasörün altı (alt klasör dahil) görünmez")

        let flat = [request("a"), request("b")]
        XCTAssertEqual(RequestTreeRows.rows(for: flat, expanded: [], collapsedFolders: [], folderID: folderID),
                       RequestTreeRows.rows(for: flat, expanded: []), "klasör yoksa eski satırlarla aynı")
    }

    /// Bırakılan yerin üstündeki satır hedef klasörü belirler; katlı klasördeki
    /// gizli istekler sırayı bozmaz.
    func testPlacementReadsTheFolderFromTheRowAbove() throws {
        let k = request("kök"), u1 = request("u1", ["U"]), u2 = request("u2", ["U"]), s = request("s", ["S"])
        let requests = [k, u1, u2, s]
        let byID = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0.folder) })
        let rows = RequestTreeRows.rows(for: requests, expanded: [], collapsedFolders: [], folderID: folderID)
        // kök, [U], u1, u2, [S], s
        func place(_ source: Int, _ destination: Int, in rows: [RequestTreeRows.Row]) throws -> [String] {
            let p = try XCTUnwrap(RequestTreeRows.placement(source: [source], destination: destination, in: rows, folderOf: { byID[$0] ?? [] }))
            return RequestFolders.placing(p.ids, in: p.folder, before: p.before, requests: requests).map { ($0.folder + [$0.name]).joined(separator: "/") }
        }
        XCTAssertEqual(try place(0, 2, in: rows), ["U/kök", "U/u1", "U/u2", "S/s"], "klasör başlığının hemen altı: klasörün başı")
        XCTAssertEqual(try place(0, 4, in: rows), ["U/u1", "U/u2", "U/kök", "S/s"], "klasörün son isteğinin altı: klasörün sonu")
        XCTAssertEqual(try place(5, 1, in: rows), ["kök", "s", "U/u1", "U/u2"], "kökün son isteğinin altı: kök")
        XCTAssertEqual(try place(3, 0, in: rows), ["u2", "kök", "U/u1"] + ["S/s"], "en baş: kök")
        XCTAssertNil(RequestTreeRows.placement(source: [1], destination: 0, in: rows, folderOf: { byID[$0] ?? [] }), "klasör satırı sürüklenmez")

        let collapsed = RequestTreeRows.rows(for: requests, expanded: [], collapsedFolders: [folderID(["U"])], folderID: folderID)
        // kök, [U] (katlı), [S], s
        XCTAssertEqual(try place(3, 2, in: collapsed), ["kök", "U/u1", "U/u2", "U/s"], "katlı klasörün başlığına bırakılan içine girer")
    }

    /// Arama klasör adını da bulur; kenar çubuğu özeti gösterim sırasındadır.
    func testSearchAndSnapshotKnowAboutFolders() {
        let collection = CollectionModel(name: "C", requests: [request("liste", ["Kullanıcı"]), request("kök")])
        let hits = RequestSearch.filter([collection], query: "kullanıcı")
        XCTAssertEqual(hits.first?.requests.map(\.name), ["liste"])
        let snapshot = SidebarSnapshot(workspace: WorkspaceModel(collections: [collection]))
        XCTAssertEqual(snapshot.collections[0].requests.map(\.name), ["kök", "liste"])
        XCTAssertEqual(snapshot.collections[0].requests.map(\.folder), [[], ["Kullanıcı"]])
    }
}
