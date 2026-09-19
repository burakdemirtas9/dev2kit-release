import XCTest
@testable import SecoraCore

final class OpenAPIImporterTests: XCTestCase {
    private let source = URL(string: "http://localhost:8080/fx-bff-service/v3/api-docs")!

    private let openAPI3: [String: Any] = [
        "openapi": "3.0.1",
        "info": ["title": "OpenAPI definition", "version": "v0"],
        "servers": [["url": "/fx-bff-service", "description": "göreli"]],
        "security": [["bearerAuth": []]],
        "paths": [
            "/rates/{code}": [
                "parameters": [["name": "code", "in": "path", "required": true, "schema": ["type": "string"]]],
                "get": [
                    "tags": ["kur"],
                    "summary": "Kur getir",
                    "parameters": [
                        ["name": "limit", "in": "query", "required": true, "schema": ["type": "integer", "default": 10]],
                        ["name": "q", "in": "query", "schema": ["type": "string"]],
                        ["name": "X-Kanal", "in": "header", "example": "MOBIL"],
                        ["name": "oturum", "in": "cookie"],
                    ],
                ],
            ],
            "/orders": [
                "post": [
                    "tags": ["emir"],
                    "operationId": "createOrder",
                    "requestBody": ["$ref": "#/components/requestBodies/Order"],
                ],
            ],
            "/public/health": [
                "get": ["summary": "Sağlık", "security": [], "deprecated": true],
            ],
            "/upload": [
                "post": [
                    "summary": "Yükle",
                    "requestBody": ["content": ["multipart/form-data": ["schema": [
                        "type": "object",
                        "properties": ["aciklama": ["type": "string"], "dosya": ["type": "string", "format": "binary"]],
                    ]]]],
                ],
            ],
        ],
        "components": [
            "securitySchemes": [
                "bearerAuth": ["type": "http", "scheme": "bearer"],
                "cc": ["type": "oauth2", "flows": ["clientCredentials": ["tokenUrl": "https://auth.ornek.com/token"]]],
            ],
            "requestBodies": ["Order": ["content": ["application/json": ["schema": ["$ref": "#/components/schemas/Order"]]]]],
            "schemas": [
                "Order": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "format": "uuid"],
                        "amount": ["type": "number"],
                        "createdAt": ["type": "string", "format": "date-time"],
                        "parent": ["$ref": "#/components/schemas/Order"],
                        "tags": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
            ],
        ],
    ]

    private func document(_ spec: [String: Any], from url: URL? = nil) throws -> OpenAPIImporter.Document {
        try OpenAPIImporter.parse(JSONSerialization.data(withJSONObject: spec), sourceURL: url ?? source)
    }

    private func collection(_ spec: [String: Any], variable: String = "fx") throws -> CollectionPorting.ImportOutcome {
        try OpenAPIImporter.makeCollection(from: document(spec), variableName: variable, existingNames: [])
    }

    private func request(_ outcome: CollectionPorting.ImportOutcome, _ name: String) throws -> RequestModel {
        try XCTUnwrap(outcome.collection.requests.first { $0.name == name }, "\(name) yok: \(outcome.collection.requests.map(\.name))")
    }

    // MARK: - Doküman

    func testRelativeServerResolvesAgainstSourceAndGenericTitleUsesServiceName() throws {
        let doc = try document(openAPI3)
        XCTAssertEqual(doc.serverURL, "http://localhost:8080/fx-bff-service")
        XCTAssertEqual(doc.suggestedName, "fx-bff-service")
        XCTAssertEqual(doc.operationCount, 4)
    }

    func testServerVariablesUseDefaults() throws {
        var spec = openAPI3
        spec["servers"] = [["url": "https://{env}.ornek.com/api/", "variables": ["env": ["default": "test"]]]]
        XCTAssertEqual(try document(spec).serverURL, "https://test.ornek.com/api")
    }

    func testSwagger2HostAndBasePath() throws {
        let spec: [String: Any] = [
            "swagger": "2.0",
            "info": ["title": "Ödeme Servisi", "version": "1"],
            "host": "api.ornek.com",
            "basePath": "/v1",
            "schemes": ["http", "https"],
            "paths": ["/payments": ["post": [
                "summary": "Öde",
                "parameters": [["name": "body", "in": "body", "schema": ["type": "object", "properties": ["tutar": ["type": "integer"]]]]],
            ]]],
        ]
        let doc = try document(spec)
        XCTAssertEqual(doc.serverURL, "https://api.ornek.com/v1")
        XCTAssertEqual(doc.suggestedName, "odeme-servisi")
        let outcome = try OpenAPIImporter.makeCollection(from: doc, variableName: "odeme", existingNames: [])
        let payment = try request(outcome, "Öde")
        XCTAssertEqual(payment.url, "{{odeme}}/payments")
        guard case .raw(let content, "application/json") = payment.body else { return XCTFail("JSON gövde bekleniyordu") }
        XCTAssertTrue(content.contains("\"tutar\" : 0"))
    }

    /// Yapıştırılan JSON: adres yok, göreli sunucu çözülemez ama ad için kullanılır.
    func testPastedDocumentWithRelativeServer() throws {
        let doc = try OpenAPIImporter.parse(JSONSerialization.data(withJSONObject: openAPI3), sourceURL: nil)
        XCTAssertNil(doc.serverURL)
        XCTAssertEqual(doc.suggestedName, "fx-bff-service")
        let notes = try OpenAPIImporter.makeCollection(from: doc, variableName: "fx", existingNames: []).warnings
        XCTAssertTrue(notes.contains { $0.contains("sunucu adresi yok") })
        XCTAssertFalse(notes.contains { $0.contains("adresinden alındı") }, "kaynak adres yokken host karşılaştırması yapılmaz")
    }

    func testPastedDocumentWithAbsoluteServerKeepsIt() throws {
        var spec = openAPI3
        spec["servers"] = [["url": "https://gw.ornek.com/fx"]]
        let doc = try OpenAPIImporter.parse(JSONSerialization.data(withJSONObject: spec), sourceURL: nil)
        XCTAssertEqual(doc.serverURL, "https://gw.ornek.com/fx")
    }

    func testYAMLAndNonOpenAPIAreRejected() {
        XCTAssertThrowsError(try OpenAPIImporter.parse(Data("openapi: 3.0.0\ninfo:".utf8), sourceURL: nil)) { error in
            XCTAssertEqual(error as? OpenAPIImporter.ImportError, .yaml)
        }
        XCTAssertThrowsError(try OpenAPIImporter.parse(Data(#"{"merhaba":1}"#.utf8), sourceURL: nil)) { error in
            XCTAssertEqual(error as? OpenAPIImporter.ImportError, .notOpenAPI)
        }
    }

    // MARK: - İstekler

    func testParametersAndNaming() throws {
        let outcome = try collection(openAPI3)
        let rates = try request(outcome, "kur / Kur getir")
        XCTAssertEqual(rates.method, .get)
        XCTAssertEqual(rates.url, "{{fx}}/rates/{{code}}")
        XCTAssertEqual(rates.queryParams.map(\.key), ["limit", "q"])
        XCTAssertEqual(rates.queryParams.map(\.value), ["10", ""])
        XCTAssertEqual(rates.queryParams.map(\.enabled), [true, false], "isteğe bağlı parametre kapalı gelmeli")
        XCTAssertEqual(rates.headers.map(\.key), ["X-Kanal"])
        XCTAssertEqual(rates.auth, .bearer(token: "{{accessToken}}"))
        XCTAssertNoThrow(try request(outcome, "Sağlık (deprecated)"))
    }

    func testRequestBodyFromReferencedSchemaSurvivesCycles() throws {
        let order = try request(try collection(openAPI3), "emir / createOrder")
        XCTAssertEqual(order.method, .post)
        XCTAssertTrue(order.headers.contains { $0.key == "Content-Type" && $0.value == "application/json" })
        guard case .raw(let content, _) = order.body else { return XCTFail("gövde bekleniyordu") }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(json["createdAt"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(json["tags"] as? [String], ["string"])
        // Kendine referans veren alan sonsuz döngüye girmez.
        XCTAssertNotNil(json["parent"])
    }

    func testPublicOperationHasNoAuthAndFileFieldsAreSkipped() throws {
        let outcome = try collection(openAPI3)
        XCTAssertEqual(try request(outcome, "Sağlık (deprecated)").auth, .none)
        let upload = try request(outcome, "Yükle")
        guard case .multipartForm(let fields) = upload.body else { return XCTFail("form-data bekleniyordu") }
        XCTAssertEqual(fields.map(\.key), ["aciklama"])
        XCTAssertTrue(outcome.warnings.contains { $0.contains("1 dosya alanı atlandı") })
        XCTAssertTrue(outcome.warnings.contains { $0.contains("1 cookie parametresi atlandı") })
    }

    func testNotesExplainVariablesAndTokenURL() throws {
        let notes = try collection(openAPI3).warnings
        XCTAssertTrue(notes.contains { $0.contains("{{fx}}") && $0.contains("http://localhost:8080/fx-bff-service") })
        XCTAssertTrue(notes.contains { $0.contains("Yol parametreleri") })
        XCTAssertTrue(notes.contains { $0.contains("https://auth.ornek.com/token") } == false, "kullanılmayan şemanın adresi yazılmaz")
    }

    func testServerOnAnotherHostIsFlagged() throws {
        var spec = openAPI3
        spec["servers"] = [["url": "https://toplayici.example"]]
        let notes = try collection(spec).warnings
        XCTAssertTrue(notes.contains { $0.contains("localhost") && $0.contains("toplayici.example") })
    }

    func testExternalReferencesAreNotFollowed() throws {
        var spec = openAPI3
        spec["paths"] = ["/x": ["post": [
            "summary": "Dış",
            "requestBody": ["content": ["application/json": ["schema": ["$ref": "https://evil.example/schema.json"]]]],
        ]]]
        let external = try request(try collection(spec), "Dış")
        guard case .raw(let content, _) = external.body else { return XCTFail("gövde bekleniyordu") }
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "{\n\n}")
    }

    func testImportedCollectionGoesThroughTheReviewer() throws {
        var spec = openAPI3
        spec["paths"] = ["/x": ["get": [
            "summary": "Örnekli",
            "parameters": [["name": "X-Token", "in": "header", "required": true, "example": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2FodGU"]],
        ]]]
        let outcome = try collection(spec)
        let review = ImportReviewer.review(collection: outcome.collection, notes: outcome.warnings, context: .init(policy: .notConfigured, vaultSecretNames: []))
        XCTAssertTrue(review.requests[0].findings.contains { $0.title == "Düz metin kimlik bilgisi" })
    }

    // MARK: - Keşif

    func testCandidatesIncludeGatewayContextPath() {
        let candidates = OpenAPIDiscovery.candidates(around: URL(string: "https://gw.ornek.com/fx-bff-service/swagger-ui/index.html?x=1")!)
        XCTAssertEqual(candidates.first?.absoluteString, "https://gw.ornek.com/fx-bff-service/v3/api-docs/swagger-config")
        XCTAssertTrue(candidates.contains { $0.absoluteString == "https://gw.ornek.com/v3/api-docs" })
    }

    func testSwaggerUIPageLeadsToTheDocumentThroughSwaggerConfig() async throws {
        let spec = try JSONSerialization.data(withJSONObject: openAPI3)
        let pages: [String: Data] = [
            "http://localhost:8080/fx-bff-service/swagger-ui/index.html": Data("<html>swagger</html>".utf8),
            "http://localhost:8080/fx-bff-service/v3/api-docs/swagger-config": Data(#"{"url":"/fx-bff-service/v3/api-docs"}"#.utf8),
            "http://localhost:8080/fx-bff-service/v3/api-docs": spec,
        ]
        let outcome = try await OpenAPIDiscovery.discover(from: URL(string: "http://localhost:8080/fx-bff-service/swagger-ui/index.html")!) { url in
            guard let data = pages[url.absoluteString] else { throw OpenAPIDiscovery.HTTPStatusError(url: url, statusCode: 404) }
            return data
        }
        guard case .document(let document) = outcome else { return XCTFail("doküman bekleniyordu") }
        XCTAssertEqual(document.operationCount, 4)
    }

    func testMultipleSpringdocGroupsAreOffered() async throws {
        let config = #"{"urls":[{"url":"/v3/api-docs/public","name":"public"},{"url":"/v3/api-docs/admin","name":"admin"}]}"#
        let outcome = try await OpenAPIDiscovery.discover(from: URL(string: "http://localhost:8080/v3/api-docs/swagger-config")!) { _ in
            Data(config.utf8)
        }
        guard case .groups(let groups) = outcome else { return XCTFail("grup listesi bekleniyordu") }
        XCTAssertEqual(groups.map(\.name), ["public", "admin"])
        XCTAssertEqual(groups.last?.url.absoluteString, "http://localhost:8080/v3/api-docs/admin")
    }

    func testOnlyHTTPErrorsMoveToTheNextCandidate() async {
        do {
            _ = try await OpenAPIDiscovery.discover(from: URL(string: "http://localhost:8080/x")!) { url in
                throw OpenAPIDiscovery.HTTPStatusError(url: url, statusCode: 404)
            }
            XCTFail("hata bekleniyordu")
        } catch let error as OpenAPIDiscovery.DiscoveryError {
            guard case .notFound(let tried) = error else { return XCTFail() }
            XCTAssertGreaterThan(tried.count, 1)
            XCTAssertLessThanOrEqual(tried.count, OpenAPIDiscovery.maxAttempts)
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
    }

    /// Politika engeli ya da kapalı sunucu: diğer yollar denenmez, asıl sebep görünür.
    func testSecurityAndConnectionErrorsStopImmediately() async {
        var attempts = 0
        do {
            _ = try await OpenAPIDiscovery.discover(from: URL(string: "http://localhost:9/x")!) { _ in
                attempts += 1
                throw RequestEngineError.securityBlocked([SecurityFinding(severity: .block, title: "Yönetici politikası", detail: "izin yok")])
            }
            XCTFail("hata bekleniyordu")
        } catch RequestEngineError.securityBlocked {
            XCTAssertEqual(attempts, 1)
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
    }
}
