import XCTest
@testable import SecoraCore

final class RequestSearchTests: XCTestCase {
    private func request(_ name: String, _ method: HTTPMethod = .get, _ url: String = "") -> RequestModel {
        RequestModel(name: name, method: method, url: url)
    }

    private func workspace() -> [CollectionModel] {
        [
            CollectionModel(name: "Kullanıcılar", requests: [
                request("Listele", .get, "https://api.example.com/users"),
                request("Oluştur", .post, "https://api.example.com/users"),
                request("Sil", .delete, "https://api.example.com/users/{{id}}"),
            ]),
            CollectionModel(name: "Ödemeler", requests: [
                request("Ödeme Başlat", .post, "https://pay.example.com/charge"),
                request("Durum", .get, "https://pay.example.com/charge/{{id}}"),
            ]),
        ]
    }

    // MARK: - Parçalama

    func testEmptyQueryHasNoTokens() {
        XCTAssertTrue(RequestSearch.tokens(from: "").isEmpty)
    }

    func testWhitespaceOnlyQueryHasNoTokens() {
        XCTAssertTrue(RequestSearch.tokens(from: "   \t \n ").isEmpty)
    }

    func testQuerySplitsOnWhitespace() {
        XCTAssertEqual(RequestSearch.tokens(from: "  post   user "), ["post", "user"])
    }

    // MARK: - Filtreleme

    func testEmptyQueryReturnsEverythingUnchanged() {
        let collections = workspace()
        let matches = RequestSearch.filter(collections, query: "")
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].requests.count, 3)
        XCTAssertEqual(matches[1].requests.count, 2)
        XCTAssertEqual(matches.map(\.id), collections.map(\.id))
    }

    func testMatchesRequestName() {
        let matches = RequestSearch.filter(workspace(), query: "durum")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].collection.name, "Ödemeler")
        XCTAssertEqual(matches[0].requests.map(\.name), ["Durum"])
    }

    func testMatchesMethod() {
        let matches = RequestSearch.filter(workspace(), query: "post")
        XCTAssertEqual(RequestSearch.totalRequests(in: matches), 2)
        XCTAssertEqual(matches.flatMap { $0.requests.map(\.name) }, ["Oluştur", "Ödeme Başlat"])
    }

    func testMatchesURLPath() {
        let matches = RequestSearch.filter(workspace(), query: "charge")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(RequestSearch.totalRequests(in: matches), 2)
    }

    func testCollectionNameMatchKeepsAllItsRequests() {
        let matches = RequestSearch.filter(workspace(), query: "ödemeler")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].requests.count, 2)
    }

    func testTokensAreCombinedWithAnd() {
        // "kullanıcılar" koleksiyon adından, "post" metottan gelir.
        let matches = RequestSearch.filter(workspace(), query: "kullanıcılar post")
        XCTAssertEqual(RequestSearch.totalRequests(in: matches), 1)
        XCTAssertEqual(matches[0].requests.map(\.name), ["Oluştur"])
    }

    func testTokenOrderDoesNotMatter() {
        let collections = workspace()
        let forward = RequestSearch.filter(collections, query: "users post")
        let reversed = RequestSearch.filter(collections, query: "post users")
        XCTAssertEqual(forward, reversed)
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(RequestSearch.filter(workspace(), query: "zzz").isEmpty)
    }

    func testCollectionsWithoutHitsAreDropped() {
        let matches = RequestSearch.filter(workspace(), query: "users")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].collection.name, "Kullanıcılar")
    }

    // MARK: - Harf ve aksan duyarsızlığı

    func testCaseInsensitive() {
        XCTAssertEqual(RequestSearch.totalRequests(in: RequestSearch.filter(workspace(), query: "LISTELE")), 1)
    }

    func testTurkishDottedCapitalMatchesLowercase() {
        let collections = [CollectionModel(name: "Test", requests: [request("İptal Et")])]
        XCTAssertEqual(RequestSearch.filter(collections, query: "iptal").count, 1)
        XCTAssertEqual(RequestSearch.filter(collections, query: "İPTAL").count, 1)
    }

    func testDiacriticInsensitive() {
        // Türkçe karakter yazmadan da bulunabilmeli: "odeme" → "Ödeme".
        XCTAssertEqual(RequestSearch.totalRequests(in: RequestSearch.filter(workspace(), query: "odeme")), 2)
    }

    // MARK: - Kenar durumları

    func testEmptyCollectionWithMatchingNameIsShownEmpty() {
        let collections = [CollectionModel(name: "Taslaklar", requests: [])]
        let matches = RequestSearch.filter(collections, query: "taslak")
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(matches[0].requests.isEmpty)
    }

    func testEmptyCollectionWithoutMatchingNameIsHidden() {
        let collections = [CollectionModel(name: "Taslaklar", requests: [])]
        XCTAssertTrue(RequestSearch.filter(collections, query: "ödeme").isEmpty)
    }

    func testNoCollectionsReturnsEmpty() {
        XCTAssertTrue(RequestSearch.filter([], query: "").isEmpty)
        XCTAssertTrue(RequestSearch.filter([], query: "a").isEmpty)
    }

    func testRequestWithEmptyURLAndDefaultNameIsSearchableByMethod() {
        let collections = [CollectionModel(name: "Yeni", requests: [request("Yeni İstek")])]
        XCTAssertEqual(RequestSearch.filter(collections, query: "get").count, 1)
    }

    func testMatchesHelperAcceptsEmptyTokens() {
        XCTAssertTrue(RequestSearch.matches(request("x"), tokens: []))
    }

    func testASCIIQueryFindsTurkishLetters() {
        // Klavyede Türkçe harf olmadan da bulunabilmeli.
        XCTAssertEqual(RequestSearch.filter(workspace(), query: "kullanicilar").count, 1)
        XCTAssertEqual(RequestSearch.filter(workspace(), query: "olustur").count, 1)
    }

    func testTurkishQueryFindsASCIIText() {
        let collections = [CollectionModel(name: "Basic", requests: [request("Login")])]
        XCTAssertEqual(RequestSearch.filter(collections, query: "BASİC").count, 1)
    }

    func testMatchingIsIndependentOfSystemLocale() {
        // Katlama sabit bir locale ile yapılıyor; sonuç makineye göre değişmemeli.
        let collections = [CollectionModel(name: "IPTAL", requests: [request("İptal")])]
        XCTAssertEqual(RequestSearch.totalRequests(in: RequestSearch.filter(collections, query: "iptal")), 1)
    }

    func testTotalRequestsOfEmptyResult() {
        XCTAssertEqual(RequestSearch.totalRequests(in: []), 0)
    }
}
