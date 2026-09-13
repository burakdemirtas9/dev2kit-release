import Foundation

/// Bir environment: `{{baseUrl}}` gibi değişkenlerin değer kümesi.
/// Secret'lar burada da durmaz; değişken değeri `{{secret:isim}}` referansı olabilir.
public struct EnvironmentModel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var variables: [KeyValueEntry]

    public init(id: UUID = UUID(), name: String = "Yeni Environment", variables: [KeyValueEntry] = []) {
        self.id = id
        self.name = name
        self.variables = variables
    }
}

/// İstek koleksiyonu. Diske okunabilir JSON olarak yazılır (git-friendly).
public struct CollectionModel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var requests: [RequestModel]

    public init(id: UUID = UUID(), name: String = "Yeni Koleksiyon", requests: [RequestModel] = []) {
        self.id = id
        self.name = name
        self.requests = requests
    }
}

/// Uygulamanın diske yazılan tüm durumu. Tek dosyada tutulur (MVP);
/// koleksiyon başına dosya ayrımı ileride eklenebilir.
public struct WorkspaceModel: Codable, Sendable {
    public var schemaVersion: Int
    public var collections: [CollectionModel]
    public var environments: [EnvironmentModel]
    public var activeEnvironmentID: UUID?

    public init(
        schemaVersion: Int = 1,
        collections: [CollectionModel] = [],
        environments: [EnvironmentModel] = [],
        activeEnvironmentID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.collections = collections
        self.environments = environments
        self.activeEnvironmentID = activeEnvironmentID
    }
}
