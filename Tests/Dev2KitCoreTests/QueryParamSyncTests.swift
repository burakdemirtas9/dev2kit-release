import XCTest
@testable import Dev2KitCore

/// Kullanıcı isteği (2026-10-19): Params tablosuna yazılan adres çubuğuna
/// sırayla eklensin (Postman gibi), adrese yazılan tabloya düşsün.
final class QueryParamSyncTests: XCTestCase {
    private func entry(_ key: String, _ value: String, enabled: Bool = true) -> KeyValueEntry {
        KeyValueEntry(key: key, value: value, enabled: enabled)
    }

    func testTableToURLKeepsOrderAndSkipsDisabledAndUnnamedRows() {
        let params = [entry("name", "xyz"), entry("gizli", "1", enabled: false), entry("", "yarım"), entry("page", "2")]
        XCTAssertEqual(QueryParamSync.url("https://api.example.com/v1/users", with: params), "https://api.example.com/v1/users?name=xyz&page=2")
        // Var olan sorgu yeniden yazılır, fragment korunur.
        XCTAssertEqual(QueryParamSync.url("https://a.example.com/x?eski=1#bolum", with: [entry("q", "1")]), "https://a.example.com/x?q=1#bolum")
        XCTAssertEqual(QueryParamSync.url("https://a.example.com/x?eski=1", with: []), "https://a.example.com/x")
    }

    func testTemplatesStayRawAndSeparatorsAreEncoded() {
        let url = QueryParamSync.url("{{base}}/search", with: [entry("q", "a&b#c"), entry("t", "{{token}}"), entry("k=v", "1")])
        XCTAssertEqual(url, "{{base}}/search?q=a%26b%23c&t={{token}}&k%3Dv=1")
        XCTAssertEqual(QueryParamSync.pairs(in: url), [.init(key: "q", value: "a&b#c"), .init(key: "t", value: "{{token}}"), .init(key: "k=v", value: "1")])
    }

    func testURLToTableUpdatesInPlaceKeepingIDsAndUnrepresentableRows() {
        let current = [entry("name", "x"), entry("off", "1", enabled: false), entry("", "yazılıyor"), entry("old", "1")]
        let result = QueryParamSync.params(fromURL: "https://a.example.com/u?name=xyz&page=2&new=3", current: current)
        XCTAssertEqual(result.map(\.key), ["name", "off", "", "page", "new"])
        XCTAssertEqual(result.map(\.value), ["xyz", "1", "yazılıyor", "2", "3"])
        XCTAssertEqual(result[0].id, current[0].id, "kimlik korunur: yazarken odak kaybolmaz")
        XCTAssertEqual(result[3].id, current[3].id)
    }

    func testRoundTripIsStable() {
        // Eşitleme ping-pong yapmamalı: tablo → adres → tablo aynı kalır.
        let params = [entry("name", "Ali Veli"), entry("şehir", "İzmir"), entry("q", "a&b"), entry("off", "x", enabled: false)]
        let url = QueryParamSync.url("https://a.example.com/u", with: params)
        XCTAssertEqual(QueryParamSync.params(fromURL: url, current: params), params)
        XCTAssertEqual(QueryParamSync.url(url, with: QueryParamSync.params(fromURL: url, current: params)), url)
    }

    func testParamsAreNotSentTwice() throws {
        let engine = RequestEngine()
        let resolver = VariableResolver(environment: nil, secretStore: InMemorySecretStore())
        // Eşitlenmiş: adreste de tabloda da aynı parametre → bir kez.
        var synced = RequestModel(name: "r", method: .get, url: "https://a.example.com/u?name=xyz&page=2")
        synced.queryParams = [entry("name", "xyz"), entry("page", "2")]
        XCTAssertEqual(try engine.buildURLRequest(synced, resolver: resolver).url?.absoluteString, "https://a.example.com/u?name=xyz&page=2")

        // Eski kayıt: parametre yalnızca tabloda → eskisi gibi eklenir.
        var legacy = RequestModel(name: "r", method: .get, url: "https://a.example.com/u")
        legacy.queryParams = [entry("name", "xyz")]
        XCTAssertEqual(try engine.buildURLRequest(legacy, resolver: resolver).url?.absoluteString, "https://a.example.com/u?name=xyz")

        // Bilinçli tekrar (?a=1&a=1) korunur: her adres eşleşmesi bir kez tüketilir.
        var repeated = RequestModel(name: "r", method: .get, url: "https://a.example.com/u?a=1&a=1")
        repeated.queryParams = [entry("a", "1"), entry("a", "1")]
        XCTAssertEqual(try engine.buildURLRequest(repeated, resolver: resolver).url?.absoluteString, "https://a.example.com/u?a=1&a=1")
    }

    func testTurkishAndSpacesAreEncodedWhenSent() throws {
        let engine = RequestEngine()
        let resolver = VariableResolver(environment: nil, secretStore: InMemorySecretStore())
        let url = QueryParamSync.url("https://a.example.com/u", with: [entry("ad", "Ali Veli"), entry("şehir", "İzmir")])
        let request = RequestModel(name: "r", method: .get, url: url)
        let sent = try XCTUnwrap(engine.buildURLRequest(request, resolver: resolver).url)
        let items = URLComponents(url: sent, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.map(\.name), ["ad", "şehir"])
        XCTAssertEqual(items?.map(\.value), ["Ali Veli", "İzmir"])
    }

    // MARK: Düzenleme sonrası (eski kayıtlar veri kaybetmemeli)

    func testEditingTheTableOfALegacyRequestKeepsURLOnlyParams() {
        // Eski kayıt: adreste a=1, tabloda yalnızca b=2 (ikisi de gönderiliyordu).
        let before = [entry("b", "2")]
        var after = before
        after[0].value = "3"
        let synced = QueryParamSync.afterParamsEdit(url: "https://a.example.com/u?a=1", paramsBefore: before, params: after)
        XCTAssertEqual(synced.url, "https://a.example.com/u?a=1&b=3")
        XCTAssertEqual(synced.params.map(\.key), ["a", "b"])
    }

    func testEditingAValueDoesNotLeaveTheOldValueBehind() {
        let before = [entry("name", "xyz")]
        var after = before
        after[0].value = "abc"
        let synced = QueryParamSync.afterParamsEdit(url: "https://a.example.com/u?name=xyz", paramsBefore: before, params: after)
        XCTAssertEqual(synced.url, "https://a.example.com/u?name=abc")
        XCTAssertEqual(synced.params.count, 1)
    }

    func testEditingTheHostOfALegacyRequestDoesNotTouchTheTable() {
        let params = [entry("name", "xyz")] // yalnızca tabloda
        let synced = QueryParamSync.afterURLEdit(urlBefore: "https://a.example.com/u", url: "https://b.example.com/u", params: params)
        XCTAssertEqual(synced, .init(url: "https://b.example.com/u", params: params))
    }

    func testTypingAQueryIntoALegacyRequestKeepsTableOnlyParams() {
        let params = [entry("name", "xyz")] // yalnızca tabloda (gizli)
        let synced = QueryParamSync.afterURLEdit(urlBefore: "https://a.example.com/u", url: "https://a.example.com/u?page=1", params: params)
        XCTAssertEqual(synced.params.map(\.key), ["page", "name"])
        XCTAssertEqual(synced.url, "https://a.example.com/u?page=1&name=xyz", "gizli parametre artık görünür")
    }

    func testRemovingAParamFromTheURLRemovesItFromTheTable() {
        let params = [entry("a", "1"), entry("b", "2")]
        let synced = QueryParamSync.afterURLEdit(urlBefore: "https://x.example.com/?a=1&b=2", url: "https://x.example.com/?a=1", params: params)
        XCTAssertEqual(synced.params.map(\.key), ["a"])
    }

}
