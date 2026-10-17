import XCTest
@testable import Dev2KitCore

final class CollectionPortingTests: XCTestCase {
    // MARK: - dev2kit roundtrip

    func testExportImportRoundtrip() throws {
        var request = RequestModel(name: "Kullanıcılar", method: .post, url: "{{baseUrl}}/users")
        request.auth = .bearer(token: "{{secret:t}}")
        let collection = CollectionModel(name: "API", requests: [request])

        let data = try CollectionPorting.exportData(collection)
        let outcome = try CollectionPorting.importDev2Kit(data, existingNames: [])

        XCTAssertEqual(outcome.collection.name, "API")
        XCTAssertFalse(outcome.wasRenamed)
        XCTAssertEqual(outcome.collection.requests.count, 1)
        XCTAssertEqual(outcome.collection.requests[0].url, "{{baseUrl}}/users")
        // ID'ler yeniden üretilmeli: aynı workspace'e iki kez import çakışmamalı.
        XCTAssertNotEqual(outcome.collection.id, collection.id)
        XCTAssertNotEqual(outcome.collection.requests[0].id, request.id)
    }

    func testDev2KitNameConflictAppendsNew() throws {
        let data = try CollectionPorting.exportData(CollectionModel(name: "API"))
        let outcome = try CollectionPorting.importDev2Kit(data, existingNames: ["API"])
        XCTAssertEqual(outcome.collection.name, "API New")
        XCTAssertTrue(outcome.wasRenamed)
    }

    func testNameConflictFallsBackToNumbers() throws {
        let (name, renamed) = try CollectionPorting.resolveName(
            "API", suffix: "New", existingNames: ["API", "API New", "API New 2"]
        )
        XCTAssertEqual(name, "API New 3")
        XCTAssertTrue(renamed)
    }

    func testNameConflictExhaustionThrows() {
        var names = ["API", "API New"]
        names += (2...50).map { "API New \($0)" }
        XCTAssertThrowsError(
            try CollectionPorting.resolveName("API", suffix: "New", existingNames: names)
        ) { error in
            guard case CollectionPorting.PortingError.nameConflictUnresolved = error else {
                return XCTFail("nameConflictUnresolved bekleniyordu")
            }
        }
    }

    func testInvalidDev2KitFileThrows() {
        XCTAssertThrowsError(try CollectionPorting.importDev2Kit(Data("bozuk".utf8), existingNames: []))
    }

    // MARK: - Postman import

    private let postmanJSON = """
    {
      "info": { "name": "Benim API", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
      "item": [
        {
          "name": "Login",
          "request": {
            "method": "POST",
            "url": { "raw": "{{baseUrl}}/login" },
            "header": [
              { "key": "X-Trace", "value": "1" },
              { "key": "X-Off", "value": "0", "disabled": true }
            ],
            "body": {
              "mode": "raw",
              "raw": "{\\"user\\":\\"a\\"}",
              "options": { "raw": { "language": "json" } }
            },
            "auth": {
              "type": "bearer",
              "bearer": [ { "key": "token", "value": "{{token}}" } ]
            }
          }
        },
        {
          "name": "Klasörüm",
          "item": [
            {
              "name": "Form",
              "request": {
                "method": "POST",
                "url": "https://api.example.com/form",
                "body": {
                  "mode": "formdata",
                  "formdata": [
                    { "key": "ad", "value": "x", "type": "text" },
                    { "key": "dosya", "type": "file" }
                  ]
                }
              }
            }
          ]
        }
      ]
    }
    """

    func testPostmanImport() throws {
        let outcome = try CollectionPorting.importPostman(Data(postmanJSON.utf8), existingNames: [])
        XCTAssertEqual(outcome.collection.name, "Benim API")
        XCTAssertEqual(outcome.collection.requests.count, 2)

        let login = outcome.collection.requests[0]
        XCTAssertEqual(login.name, "Login")
        XCTAssertEqual(login.method, .post)
        XCTAssertEqual(login.url, "{{baseUrl}}/login")
        XCTAssertEqual(login.headers.count, 2)
        XCTAssertFalse(login.headers[1].enabled)
        XCTAssertEqual(login.auth, .bearer(token: "{{token}}"))
        if case .raw(let content, let contentType) = login.body {
            XCTAssertEqual(content, #"{"user":"a"}"#)
            XCTAssertEqual(contentType, "application/json")
        } else {
            XCTFail("raw body bekleniyordu")
        }

        let form = outcome.collection.requests[1]
        XCTAssertEqual(form.name, "Klasörüm / Form")
        if case .multipartForm(let fields) = form.body {
            XCTAssertEqual(fields.map(\.key), ["ad"], "dosya alanı atlanmalı")
        } else {
            XCTFail("multipart body bekleniyordu")
        }

        XCTAssertTrue(outcome.warnings.contains { $0.contains("dosya") })
        XCTAssertTrue(outcome.warnings.contains { $0.contains("Klasörler") })
    }

    func testPostmanNameConflictAppendsFromPostman() throws {
        let outcome = try CollectionPorting.importPostman(
            Data(postmanJSON.utf8),
            existingNames: ["Benim API"]
        )
        XCTAssertEqual(outcome.collection.name, "Benim API fromPostman")
        XCTAssertTrue(outcome.wasRenamed)
    }

    func testPostmanAPIWrapperAccepted() throws {
        let wrapped = "{\"collection\": \(postmanJSON)}"
        let outcome = try CollectionPorting.importPostman(Data(wrapped.utf8), existingNames: [])
        XCTAssertEqual(outcome.collection.name, "Benim API")
        XCTAssertEqual(outcome.collection.requests.count, 2)
    }

    func testInvalidPostmanFileThrows() {
        XCTAssertThrowsError(try CollectionPorting.importPostman(Data("[1,2]".utf8), existingNames: []))
    }
}

final class UngroupedCollectionTests: XCTestCase {
    func testOldFilesDecodeAsRegularCollections() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"API","requests":[]}"#
        let collection = try JSONDecoder().decode(CollectionModel.self, from: Data(json.utf8))
        XCTAssertFalse(collection.isUngrouped)
    }

    func testUngroupedFlagRoundTrips() throws {
        let original = CollectionModel(name: CollectionModel.ungroupedName, isUngrouped: true)
        let decoded = try JSONDecoder().decode(CollectionModel.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(decoded.isUngrouped)
    }

    func testEnsureUngroupedIsIdempotentAndPinnedFirst() {
        var workspace = WorkspaceModel(collections: [CollectionModel(name: "A"), CollectionModel(name: "B")])
        let first = workspace.ensureUngroupedCollection()
        let second = workspace.ensureUngroupedCollection()
        XCTAssertEqual(first, second)
        XCTAssertEqual(workspace.collections.count, 3)
        XCTAssertEqual(workspace.collections.first?.id, first)
        XCTAssertEqual(workspace.regularCollections.map(\.name), ["A", "B"])
    }

    func testImportedFileCannotCreateASecondUngroupedCollection() throws {
        let data = try CollectionPorting.exportData(CollectionModel(name: "Sahte", isUngrouped: true))
        let outcome = try CollectionPorting.importDev2Kit(data, existingNames: [])
        XCTAssertFalse(outcome.collection.isUngrouped)
    }

    func testImportedFileCannotCreateASecondTokenFactory() throws {
        // Token Factory'deki istekler tüm isteklere token yazar; dışarıdan
        // gelen bir dosya kendini sessizce oraya yerleştirememeli.
        let data = try CollectionPorting.exportData(CollectionModel(name: "Sahte", isTokenFactory: true))
        let outcome = try CollectionPorting.importDev2Kit(data, existingNames: [])
        XCTAssertFalse(outcome.collection.isTokenFactory)
        XCTAssertTrue(outcome.collection.isRegular)
    }
}
