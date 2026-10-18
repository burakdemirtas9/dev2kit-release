import XCTest
@testable import Dev2KitCore

final class BodyKindTests: XCTestCase {
    // MARK: - Tip eşlemesi

    func testKindMatchesCase() {
        XCTAssertEqual(RequestBody.none.kind, .none)
        XCTAssertEqual(RequestBody.raw(content: "x", contentType: "application/json").kind, .raw)
        XCTAssertEqual(RequestBody.formURLEncoded(fields: []).kind, .urlEncoded)
        XCTAssertEqual(RequestBody.multipartForm(fields: []).kind, .formData)
    }

    func testEmptyRawDefaultsToJSON() {
        XCTAssertEqual(RequestBody.empty(.raw).rawContentType, "application/json")
        XCTAssertEqual(RequestBody.empty(.raw).rawContent, "")
    }

    // MARK: - Alan erişimi

    func testWrongKindReadsAreEmptyAndWritesAreIgnored() {
        // Yanlış tipe yazmak veriyi bozardı; sessizce yok sayılır.
        let none = RequestBody.none
        XCTAssertEqual(none.rawContent, "")
        XCTAssertEqual(none.formFields, [])
        XCTAssertEqual(none.settingRawContent("x"), .none)
        XCTAssertEqual(none.settingFormFields([KeyValueEntry(key: "a", value: "b")]), .none)
    }

    func testRawAccessorsRoundTrip() {
        let body = RequestBody.raw(content: "{}", contentType: "application/json")
        XCTAssertEqual(body.settingRawContent("[1]").rawContent, "[1]")
        XCTAssertEqual(body.settingRawContent("[1]").rawContentType, "application/json")
        XCTAssertEqual(body.settingRawContentType("text/plain").rawContentType, "text/plain")
        XCTAssertEqual(body.settingRawContentType("text/plain").rawContent, "{}")
    }

    func testFormFieldsKeepTheirKind() {
        let fields = [KeyValueEntry(key: "a", value: "1")]
        XCTAssertEqual(RequestBody.formURLEncoded(fields: []).settingFormFields(fields),
                       .formURLEncoded(fields: fields))
        XCTAssertEqual(RequestBody.multipartForm(fields: []).settingFormFields(fields),
                       .multipartForm(fields: fields))
    }

    // MARK: - Taslaklar

    func testSwitchingAwayAndBackKeepsContent() {
        var drafts = BodyDrafts()
        let json = RequestBody.raw(content: "{\"a\":1}", contentType: "application/json")
        let asForm = drafts.switching(json, to: .formData)
        XCTAssertEqual(asForm.kind, .formData)
        let back = drafts.switching(asForm, to: .raw)
        XCTAssertEqual(back, json, "Yazılan JSON geri dönüşte korunmalıydı")
    }

    func testNewKindStartsEmpty() {
        var drafts = BodyDrafts()
        let switched = drafts.switching(.none, to: .urlEncoded)
        XCTAssertEqual(switched, .formURLEncoded(fields: []))
    }

    func testSameKindIsNoOp() {
        var drafts = BodyDrafts()
        let body = RequestBody.raw(content: "x", contentType: "text/plain")
        XCTAssertEqual(drafts.switching(body, to: .raw), body)
        XCTAssertNil(drafts.draft(for: .raw), "Değişiklik yokken taslak saklanmamalı")
    }

    func testFormFieldsSurviveRoundTrip() {
        var drafts = BodyDrafts()
        let form = RequestBody.multipartForm(fields: [KeyValueEntry(key: "dosya", value: "x")])
        let raw = drafts.switching(form, to: .raw)
        XCTAssertEqual(drafts.switching(raw, to: .formData), form)
    }

    func testContentTypePerKind() {
        XCTAssertEqual(Beautifier.Kind.json.contentType, "application/json")
        XCTAssertEqual(Beautifier.Kind.plain.contentType, "text/plain")
        XCTAssertEqual(Beautifier.kind(contentType: "application/xml; charset=utf-8"), .xml)
        XCTAssertEqual(Beautifier.kind(contentType: "bilinmeyen"), .plain)
    }
}

final class RequestBodyContentTests: XCTestCase {
    func testHasContent() {
        XCTAssertFalse(RequestBody.none.hasContent)
        XCTAssertFalse(RequestBody.raw(content: "  \n ", contentType: "application/json").hasContent)
        XCTAssertTrue(RequestBody.raw(content: "{}", contentType: "application/json").hasContent)
        XCTAssertFalse(RequestBody.formURLEncoded(fields: []).hasContent)
        XCTAssertFalse(RequestBody.formURLEncoded(fields: [KeyValueEntry()]).hasContent, "boş satır içerik değil")
        XCTAssertFalse(RequestBody.multipartForm(fields: [KeyValueEntry(key: "a", value: "1", enabled: false)]).hasContent, "kapalı alan gönderilmez")
        XCTAssertTrue(RequestBody.multipartForm(fields: [KeyValueEntry(key: "a", value: "")]).hasContent)
    }
}
