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
    /// İsteğin en son BAŞARIYLA GÖNDERİLDİĞİ hali; anahtar istek kimliğidir.
    ///
    /// "Şu an baktığın şey, en son test ettiğinden farklı" işaretinin ve
    /// "son gönderilen hale dön" komutunun dayanağı. Sözlük anahtarı
    /// String tutulur ki dosya git diff'lerinde okunabilir kalsın.
    public var sentBaselines: [String: RequestModel]

    public init(
        schemaVersion: Int = 1,
        collections: [CollectionModel] = [],
        environments: [EnvironmentModel] = [],
        activeEnvironmentID: UUID? = nil,
        sentBaselines: [String: RequestModel] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.collections = collections
        self.environments = environments
        self.activeEnvironmentID = activeEnvironmentID
        self.sentBaselines = sentBaselines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            collections: try container.decodeIfPresent([CollectionModel].self, forKey: .collections) ?? [],
            environments: try container.decodeIfPresent([EnvironmentModel].self, forKey: .environments) ?? [],
            activeEnvironmentID: try container.decodeIfPresent(UUID.self, forKey: .activeEnvironmentID),
            // Bu alan eklenmeden önce yazılmış dosyalarda yok.
            sentBaselines: try container.decodeIfPresent([String: RequestModel].self, forKey: .sentBaselines) ?? [:]
        )
    }

    /// Silinmiş isteklerin referans noktalarını atar; dosya şişmesin.
    public mutating func pruneBaselines() {
        let liveIDs = Set(collections.flatMap { $0.requests.map(\.id.uuidString) })
        sentBaselines = sentBaselines.filter { liveIDs.contains($0.key) }
    }
}
