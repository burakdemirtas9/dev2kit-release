import Foundation

/// Eski "token değişkenleri"ni (environment içinde, yalnızca OAuth2 client
/// credentials) Token Factory isteklerine taşır.
///
/// Neden taşıma, neden ikisi yan yana değil: aynı işi yapan iki yol olunca
/// hangisinin geçerli olduğu belirsizleşiyordu. Client credentials akışı da
/// sonuçta bir form POST'u; Token Factory isteği olarak birebir ifade ediliyor.
///
/// Davranış korunur:
/// - Değişken adı aynı kalır (`{{accessToken}}` kullanan istekler bozulmaz).
/// - Eski değişken environment'a bağlıydı; taşınan istek de o environment'a
///   bağlanır (`TokenOutput.environmentID`), başka environment'ta devreye girmez.
/// - Adres, client bilgileri ve scope şablon olarak aynen taşınır;
///   `{{secret:…}}` referansları çözülmez, diske düz değer yazılmaz.
public enum TokenFactoryMigration {
    /// Taşınan değişken sayısını döner; 0 ise workspace'e dokunulmamıştır.
    @discardableResult
    public static func migrate(_ workspace: inout WorkspaceModel) -> Int {
        let pending = workspace.environments.flatMap { environment in
            environment.tokenVariables.map { (environment, $0) }
        }
        guard !pending.isEmpty else { return 0 }

        let factoryID = workspace.ensureTokenFactoryCollection()
        guard let index = workspace.collections.firstIndex(where: { $0.id == factoryID }) else { return 0 }
        for (environment, variable) in pending {
            workspace.collections[index].requests.append(request(from: variable, environment: environment))
        }
        for environmentIndex in workspace.environments.indices {
            workspace.environments[environmentIndex].tokenVariables = []
        }
        return pending.count
    }

    /// Eski değişkenin karşılığı olan istek.
    ///
    /// Eski akış (`OAuth2Client.clientCredentialsRequest`) ile aynı tel çıktısı:
    /// form gövdesinde `grant_type=client_credentials`, varsa `scope`; client
    /// kimliği seçime göre Basic başlığında ya da gövdede. Tek fark: eski akış
    /// Basic başlığından önce kimliği form kodluyordu (RFC 6749 §2.3.1), genel
    /// Basic auth kodlamıyor. Harf/rakam/`-._` dışı karakter içermeyen client
    /// kimliklerinde (pratikte hepsi) tel çıktısı aynıdır.
    static func request(from variable: TokenVariable, environment: EnvironmentModel) -> RequestModel {
        var fields = [KeyValueEntry(key: "grant_type", value: "client_credentials")]
        let scope = variable.scope.trimmingCharacters(in: .whitespaces)
        if !scope.isEmpty { fields.append(KeyValueEntry(key: "scope", value: scope)) }

        var auth = AuthConfig.none
        switch variable.clientAuthentication {
        case .basicHeader:
            auth = .basic(username: variable.clientID, password: variable.clientSecret)
        case .requestBody:
            fields.append(KeyValueEntry(key: "client_id", value: variable.clientID))
            fields.append(KeyValueEntry(key: "client_secret", value: variable.clientSecret))
        }

        let name = variable.trimmedName.isEmpty ? TokenOutput.defaultVariableName : variable.trimmedName
        return RequestModel(
            name: "\(name) (\(environment.name))",
            method: .post,
            url: variable.tokenURL,
            headers: [KeyValueEntry(key: "Accept", value: "application/json")],
            body: .formURLEncoded(fields: fields),
            auth: auth,
            tokenOutput: TokenOutput(
                responseField: TokenOutput.defaultResponseField,
                variableName: name,
                environmentID: environment.id
            )
        )
    }
}
