import XCTest
@testable import BoltDockCore

final class CollectionPortingTests: XCTestCase {
    // MARK: - BoltDock roundtrip

    func testExportImportRoundtrip() throws {
        var request = RequestModel(name: "Kullanıcılar", method: .post, url: "{{baseUrl}}/users")
        request.auth = .bearer(token: "{{secret:t}}")
        let collection = CollectionModel(name: "API", requests: [request])

        let data = try CollectionPorting.exportData(collection)
        let outcome = try CollectionPorting.importBoltDock(data, existingNames: [])

        XCTAssertEqual(outcome.collection.name, "API")
        XCTAssertFalse(outcome.wasRenamed)
        XCTAssertEqual(outcome.collection.requests.count, 1)
        XCTAssertEqual(outcome.collection.requests[0].url, "{{baseUrl}}/users")
        // ID'ler yeniden üretilmeli: aynı workspace'e iki kez import çakışmamalı.
        XCTAssertNotEqual(outcome.collection.id, collection.id)
        XCTAssertNotEqual(outcome.collection.requests[0].id, request.id)
    }

    func testBoltDockNameConflictAppendsNew() throws {
        let data = try CollectionPorting.exportData(CollectionModel(name: "API"))
        let outcome = try CollectionPorting.importBoltDock(data, existingNames: ["API"])
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

    func testInvalidBoltDockFileThrows() {
        XCTAssertThrowsError(try CollectionPorting.importBoltDock(Data("bozuk".utf8), existingNames: []))
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
