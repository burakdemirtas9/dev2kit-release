import XCTest
@testable import Dev2KitCore

final class IdentifiableLookupTests: XCTestCase {
    func testFindsByIdentity() {
        let collections = [CollectionModel(name: "a"), CollectionModel(name: "b")]
        XCTAssertEqual(collections.firstIndex(id: collections[1].id), 1)
        XCTAssertNil(collections.firstIndex(id: UUID()))
        XCTAssertNil([CollectionModel]().firstIndex(id: UUID()))
    }
}
