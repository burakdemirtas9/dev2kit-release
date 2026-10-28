import XCTest
@testable import Dev2KitCore

/// JSON gövdede değişkenin bozduğu gövdenin düzeltilmesi (kullanıcı kararı,
/// 2026-10-28): geçerli gövde bayt bayt aynı gider, yalnızca bozan değer
/// kaçışlanır. Yalnızca API Client; Workbench'te değişken yok.
final class JSONBodyResolutionTests: XCTestCase {
    private let json = "application/json"

    private func resolver(_ variables: [String: String], secrets: [String: String] = [:]) -> VariableResolver {
        let environment = EnvironmentModel(name: "Test", variables: variables.map { KeyValueEntry(key: $0.key, value: $0.value) })
        return VariableResolver(environment: environment, secretStore: InMemorySecretStore(initial: secrets))
    }

    private func resolve(_ body: String, _ variables: [String: String], secrets: [String: String] = [:],
                         contentType: String = "application/json") throws -> JSONBodyResolution.Result {
        try JSONBodyResolution.resolve(body, contentType: contentType, resolver: resolver(variables, secrets: secrets))
    }

    /// `text`'in JSON olarak çözülmüş hali.
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: - Bugünkü davranış korunur

    func testValidBodyIsSentByteForByte() throws {
        let body = #"{ "name": "{{name}}", "count": {{count}}, "ok": {{ok}} }"#
        let result = try resolve(body, ["name": "Ali", "count": "3", "ok": "true"])
        XCTAssertEqual(result.text, #"{ "name": "Ali", "count": 3, "ok": true }"#)
        XCTAssertEqual(result.escapedVariables, [])
    }

    /// Elle kaçışlanmış değer zaten geçerli: dokunulmaz (çift kaçış yok).
    func testHandEscapedValueIsKept() throws {
        let result = try resolve(#"{"q": "{{q}}"}"#, ["q": #"a\"b\nc"#])
        XCTAssertEqual(result.text, #"{"q": "a\"b\nc"}"#)
        XCTAssertEqual(result.escapedVariables, [])
    }

    func testNonJSONBodiesAreUntouched() throws {
        for type in ["text/plain", "application/xml", ""] {
            let result = try resolve(#"<a>"{{name}}"</a>"#, ["name": #"Ali "Veli""#], contentType: type)
            XCTAssertEqual(result.text, #"<a>"Ali "Veli""</a>"#, type)
            XCTAssertEqual(result.escapedVariables, [], type)
        }
    }

    // MARK: - Bozan değer düzeltilir

    func testQuoteInValueIsEscaped() throws {
        let result = try resolve(#"{"name": "{{name}}", "count": {{count}}}"#, ["name": #"Ali "Veli""#, "count": "3"])
        XCTAssertEqual(result.text, #"{"name": "Ali \"Veli\"", "count": 3}"#)
        XCTAssertEqual(result.escapedVariables, ["name"])
        XCTAssertEqual(try object(result.text)["name"] as? String, #"Ali "Veli""#)
    }

    func testBackslashesLineBreaksAndTabsAreEscaped() throws {
        let values = ["path": #"C:\path"#, "trailing": #"abc\"#, "multi": "a\nb\tc", "control": "x\u{01}y"]
        let body = #"{"path": "{{path}}", "trailing": "{{trailing}}", "multi": "{{multi}}", "control": "{{control}}"}"#
        let result = try resolve(body, values)
        let decoded = try object(result.text)
        for (key, value) in values {
            XCTAssertEqual(decoded[key] as? String, value, "\(key) değeri sunucuya aynen ulaşır")
        }
        XCTAssertEqual(Set(result.escapedVariables), Set(values.keys))
    }

    /// Bir doğru, bir bozuk değer: yalnızca bozuk olan kaçışlanır; doğrunun
    /// kendi kaçışı korunur.
    func testOnlyTheBreakingValueIsEscaped() throws {
        let result = try resolve(#"{"a": "{{a}}", "b": "{{b}}"}"#, ["a": #"x\"y"#, "b": #"Ali "Veli""#])
        XCTAssertEqual(result.text, #"{"a": "x\"y", "b": "Ali \"Veli\""}"#)
        XCTAssertEqual(result.escapedVariables, ["b"])
    }

    /// Tırnak dışı (sayı, true/false, JSON parçası) değişmez.
    func testValuesOutsideQuotesAreLeftAsIs() throws {
        let result = try resolve(#"{"payload": {{payload}}, "name": "{{name}}"}"#,
                                 ["payload": #"{"id": 7, "tags": ["a"]}"#, "name": #"Ali "V""#])
        XCTAssertEqual(result.text, #"{"payload": {"id": 7, "tags": ["a"]}, "name": "Ali \"V\""}"#)
        XCTAssertEqual(result.escapedVariables, ["name"])
    }

    func testSeveralVariablesInOneStringAndAfterAnEscapedQuote() throws {
        let result = try resolve(#"{"s": "{{a}}-{{b}}", "t": "say \"{{b}}\""}"#, ["a": #"1"2"#, "b": "ok"])
        let decoded = try object(result.text)
        XCTAssertEqual(decoded["s"] as? String, #"1"2-ok"#)
        XCTAssertEqual(decoded["t"] as? String, #"say "ok""#)
        XCTAssertEqual(result.escapedVariables, ["a"])
    }

    /// İç içe değişken ve secret aynı kurallarla; bildirimde değer yok.
    func testNestedVariableAndSecretAreEscapedAndReportedByName() throws {
        let result = try resolve(#"{"full": "{{full}}", "key": "{{secret:apiKey}}"}"#,
                                 ["full": #"{{first}} "Q""#, "first": "Ali"],
                                 secrets: ["apiKey": #"k"1"#])
        let decoded = try object(result.text)
        XCTAssertEqual(decoded["full"] as? String, #"Ali "Q""#)
        XCTAssertEqual(decoded["key"] as? String, #"k"1"#)
        XCTAssertEqual(result.escapedVariables, ["full", "secret:apiKey"])
        XCTAssertFalse(result.escapedVariables.joined().contains(#"k"1"#), "değer bildirilmez")
    }

    /// Düzeltme de geçersizse ham metin gider (kullanıcının bilerek bozduğu JSON).
    func testStillInvalidBodyIsSentAsBefore() throws {
        let result = try resolve(#"{"name": "{{name}}", bozuk"#, ["name": #"Ali "V""#])
        XCTAssertEqual(result.text, #"{"name": "Ali "V"", bozuk"#)
        XCTAssertEqual(result.escapedVariables, [])
    }

    func testUndefinedVariableStillStopsTheRequest() {
        XCTAssertThrowsError(try resolve(#"{"a": "{{yok}}"}"#, [:])) { error in
            XCTAssertEqual(error as? VariableResolver.ResolveError, .unknownVariable("yok"))
        }
    }

    // MARK: - Gönderim ve cURL

    func testEngineSendsTheRepairedBodyAndReportsIt() throws {
        let environment = EnvironmentModel(name: "Test", variables: [KeyValueEntry(key: "name", value: #"Ali "Veli""#)])
        let resolver = VariableResolver(environment: environment, secretStore: InMemorySecretStore())
        // Yorumlu gövde: yorum önce kalkar, sonra düzeltme.
        let model = RequestModel(method: .post, url: "https://api.example.com",
                                 body: .raw(content: "{\n  // açıklama\n  \"name\": \"{{name}}\"\n}", contentType: json))
        let built = try RequestEngine().buildRequest(model, resolver: resolver)
        let sent = String(decoding: try XCTUnwrap(built.request.httpBody), as: UTF8.self)
        XCTAssertEqual(try object(sent)["name"] as? String, #"Ali "Veli""#)
        XCTAssertEqual(built.bodyEscapedVariables, ["name"])
    }

    func testCurlExportMatchesTheSentBody() throws {
        let environment = EnvironmentModel(name: "Test", variables: [KeyValueEntry(key: "name", value: #"Ali "Veli""#)])
        let model = RequestModel(method: .post, url: "https://api.example.com",
                                 body: .raw(content: #"{"name": "{{name}}"}"#, contentType: json))
        let curl = try CurlExporter.export(model, environment: environment, secretStore: InMemorySecretStore())
        XCTAssertTrue(curl.contains(#"Ali \"Veli\""#), curl)
    }
}
