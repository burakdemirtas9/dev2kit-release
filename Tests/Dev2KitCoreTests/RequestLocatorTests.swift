import XCTest
@testable import Dev2KitCore

/// İstek konumu tablosu (2026-11-01): okurken doğrulanır, tutmazsa yeniden
/// kurulur; workspace nasıl değişirse değişsin bayat konum dönmez.
final class RequestLocatorTests: XCTestCase {
    private func workspace(_ shape: [Int]) -> [CollectionModel] {
        shape.enumerated().map { index, count in
            var collection = CollectionModel(name: "C\(index)")
            collection.requests = (0..<count).map { RequestModel(name: "R\(index)-\($0)") }
            return collection
        }
    }

    private func expected(_ id: UUID, in collections: [CollectionModel]) -> RequestLocator.Location? {
        for (c, collection) in collections.enumerated() {
            if let r = collection.requests.firstIndex(where: { $0.id == id }) {
                return .init(collection: c, request: r)
            }
        }
        return nil
    }

    func testFindsEveryRequestAndCachesAfterOneBuild() {
        let collections = workspace([3, 0, 5])
        var locator = RequestLocator()
        for request in collections.flatMap(\.requests) {
            XCTAssertEqual(locator.locate(request.id, in: collections), expected(request.id, in: collections))
        }
        XCTAssertEqual(locator.rebuildCount, 1, "tek kurulum, sonrası tablodan")
        XCTAssertNil(locator.locate(UUID(), in: collections), "olmayan istek")
    }

    func testStaysCorrectAfterEveryKindOfChange() {
        var collections = workspace([4, 3])
        var locator = RequestLocator()
        let ids = collections.flatMap(\.requests).map(\.id)
        ids.forEach { _ = locator.locate($0, in: collections) }

        // Aynı koleksiyonda sıralama.
        collections[0].requests.swapAt(0, 3)
        // Başa ekleme: diğerlerinin dizini kayar.
        collections[1].requests.insert(RequestModel(name: "yeni"), at: 0)
        // Koleksiyonlar arası taşıma.
        let moved = collections[0].requests.remove(at: 1)
        collections[1].requests.append(moved)
        // Silme.
        let deleted = collections[1].requests.remove(at: 2).id
        // Koleksiyon sırası.
        collections.swapAt(0, 1)

        for request in collections.flatMap(\.requests) {
            XCTAssertEqual(locator.locate(request.id, in: collections), expected(request.id, in: collections))
        }
        XCTAssertNil(locator.locate(deleted, in: collections), "silinen bulunmaz")
    }

    func testValidCachedEntriesDoNotRebuild() {
        var collections = workspace([3])
        var locator = RequestLocator()
        let first = collections[0].requests[0].id
        _ = locator.locate(first, in: collections)
        // İçerik değişikliği (yazma) konumu bozmaz: yeniden kurulum yok.
        collections[0].requests[0].name = "değişti"
        collections[0].requests[2].url = "https://a.test"
        _ = locator.locate(first, in: collections)
        XCTAssertEqual(locator.rebuildCount, 1)
    }

    func testDuplicateIDResolvesToTheFirstOnRebuild() {
        var collections = workspace([2, 2])
        let duplicate = collections[0].requests[1]
        collections[1].requests[0] = duplicate
        var locator = RequestLocator()
        XCTAssertEqual(locator.locate(duplicate.id, in: collections), .init(collection: 0, request: 1))
    }
}
