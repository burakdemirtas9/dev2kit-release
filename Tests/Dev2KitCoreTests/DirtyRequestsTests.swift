import XCTest
@testable import Dev2KitCore

final class DirtyRequestsTests: XCTestCase {
    func testWithoutBaselineNothingIsDirty() {
        let request = RequestModel(url: "https://a")
        let collection = CollectionModel(name: "c", requests: [request])
        XCTAssertTrue(DirtyRequests.ids(in: [collection], baselines: [:]).isEmpty)
    }

    func testUnchangedRequestIsNotDirty() {
        let request = RequestModel(url: "https://a")
        let collection = CollectionModel(name: "c", requests: [request])
        let baselines = [request.id.uuidString: request]
        XCTAssertTrue(DirtyRequests.ids(in: [collection], baselines: baselines).isEmpty)
    }

    func testChangedRequestIsDirty() {
        var request = RequestModel(url: "https://a")
        let baseline = request
        request.url = "https://b"
        let collection = CollectionModel(name: "c", requests: [request])
        let baselines = [request.id.uuidString: baseline]
        XCTAssertEqual(DirtyRequests.ids(in: [collection], baselines: baselines), [request.id])
    }

    func testNameChangeAloneIsNotDirty() {
        // İşlevsel karşılaştırma: ad değişikliği "gönderilen istek değişti" demek değil.
        var request = RequestModel(url: "https://a")
        let baseline = request
        request.name = "yeni ad"
        let collection = CollectionModel(name: "c", requests: [request])
        XCTAssertTrue(DirtyRequests.ids(in: [collection], baselines: [request.id.uuidString: baseline]).isEmpty)
    }

    func testOnlyRequestsWithBaselineAreScanned() {
        var changed = RequestModel(url: "https://a")
        let baseline = changed
        changed.url = "https://b"
        let untracked = RequestModel(url: "https://c")
        let collection = CollectionModel(name: "c", requests: [changed, untracked])
        XCTAssertEqual(
            DirtyRequests.ids(in: [collection], baselines: [changed.id.uuidString: baseline]),
            [changed.id]
        )
    }

    func testSingleRequestHelperMatchesSetVersion() {
        var request = RequestModel(url: "https://a")
        let baseline = request
        request.url = "https://b"
        XCTAssertTrue(DirtyRequests.isDirty(request, baselines: [request.id.uuidString: baseline]))
        XCTAssertFalse(DirtyRequests.isDirty(request, baselines: [:]))
    }
}
