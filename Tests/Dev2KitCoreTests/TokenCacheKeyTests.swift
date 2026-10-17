import XCTest
@testable import Dev2KitCore

/// Token önbellek anahtarı: token isteğinin gönderilecek hali değişince
/// token düşer; tele çıkmayan ya da isteğin kullanmadığı şeyler dokunmaz.
final class TokenCacheKeyTests: XCTestCase {
    private let request = RequestModel(
        name: "login",
        method: .post,
        url: "{{authUrl}}/token",
        body: .formURLEncoded(fields: [KeyValueEntry(key: "username", value: "{{customerNo}}")]),
        tokenOutput: TokenOutput()
    )

    private func environment(_ pairs: [(String, String)], id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) -> EnvironmentModel {
        EnvironmentModel(id: id, name: "Test", variables: pairs.map { KeyValueEntry(key: $0.0, value: $0.1) })
    }

    private func key(_ request: RequestModel, _ environment: EnvironmentModel?) throws -> TokenCacheKey {
        let source = try XCTUnwrap(TokenFactory.sources(in: [request], environment: environment).first)
        return TokenCacheKey(source: source, environment: environment)
    }

    private lazy var base = environment([("authUrl", "https://auth"), ("customerNo", "111"), ("pageSize", "20")])

    func testSameStateGivesSameKey() throws {
        XCTAssertEqual(try key(request, base), try key(request, base))
    }

    func testRenamingDoesNotDropTheToken() throws {
        var renamed = request
        renamed.name = "başka ad"
        XCTAssertEqual(try key(renamed, base), try key(request, base))
    }

    func testChangingWhatIsSentDropsTheToken() throws {
        var body = request
        body.body = .formURLEncoded(fields: [KeyValueEntry(key: "username", value: "sabit")])
        var url = request
        url.url = "https://baska/token"
        var header = request
        header.headers = [KeyValueEntry(key: "X-Tenant", value: "a")]
        var field = request
        field.tokenOutput = TokenOutput(responseField: "id_token")
        for changed in [body, url, header, field] {
            XCTAssertNotEqual(try key(changed, base), try key(request, base))
        }
    }

    func testChangingAUsedEnvironmentValueDropsTheToken() throws {
        // Asıl senaryo: aynı environment'ta müşteri değişti; 111'in token'ı 222'ye gitmemeli.
        let other = environment([("authUrl", "https://auth"), ("customerNo", "222"), ("pageSize", "20")])
        XCTAssertNotEqual(try key(request, other), try key(request, base))
    }

    func testValuesUsedThroughOtherVariablesCount() throws {
        // {{authUrl}} → {{host}}: host değişince de token değişmeli.
        let first = environment([("authUrl", "https://{{host}}"), ("host", "a"), ("customerNo", "1")])
        let second = environment([("authUrl", "https://{{host}}"), ("host", "b"), ("customerNo", "1")])
        XCTAssertNotEqual(try key(request, first), try key(request, second))
    }

    func testUnusedEnvironmentValuesDoNotDropTheToken() throws {
        let other = environment([("authUrl", "https://auth"), ("customerNo", "111"), ("pageSize", "50"), ("yeni", "x")])
        XCTAssertEqual(try key(request, other), try key(request, base))
    }

    func testDefiningAMissingVariableChangesTheKey() throws {
        let missing = environment([("authUrl", "https://auth")])
        XCTAssertNotEqual(try key(request, missing), try key(request, base))
    }

    func testDisabledVariablesDoNotCount() throws {
        var withDisabled = base
        withDisabled.variables.append(KeyValueEntry(key: "customerNo", value: "999", enabled: false))
        withDisabled.variables.removeAll { $0.key == "customerNo" && $0.enabled }
        let undefined = environment([("authUrl", "https://auth"), ("pageSize", "20")])
        XCTAssertEqual(try key(request, withDisabled), try key(request, undefined))
    }

    func testVaultReferencesAreNotPartOfTheKey() throws {
        // Vault okunmadan anahtar kurulur; secret yenilenmesi bilerek kapsam dışı.
        var withSecret = request
        withSecret.auth = .basic(username: "client", password: "{{secret:client-secret}}")
        XCTAssertEqual(try key(withSecret, base).variables, try key(request, base).variables)
    }

    func testEnvironmentsAreKeptApart() throws {
        let prod = environment(
            [("authUrl", "https://auth"), ("customerNo", "111"), ("pageSize", "20")],
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        XCTAssertNotEqual(try key(request, prod), try key(request, base))
        XCTAssertNotEqual(try key(request, nil), try key(request, base))
    }

    func testLiveKeysCoverEveryEnvironmentAndNoEnvironment() throws {
        var workspace = WorkspaceModel(collections: [], environments: [base])
        let factoryID = workspace.ensureTokenFactoryCollection()
        let index = try XCTUnwrap(workspace.collections.firstIndex { $0.id == factoryID })
        workspace.collections[index].requests = [request]

        let live = TokenFactory.liveCacheKeys(in: workspace)
        XCTAssertEqual(live, [try key(request, base), try key(request, nil)])

        // İstek ya da environment silinince anahtarı da canlı değildir.
        workspace.environments = []
        XCTAssertFalse(TokenFactory.liveCacheKeys(in: workspace).contains(try key(request, base)))
        workspace.collections[index].requests = []
        XCTAssertTrue(TokenFactory.liveCacheKeys(in: workspace).isEmpty)
    }
}
