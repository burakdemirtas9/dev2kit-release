import Foundation

/// Bir environment: `{{baseUrl}}` gibi değişkenlerin değer kümesi.
/// Secret'lar burada da durmaz; değişken değeri `{{secret:isim}}` referansı olabilir.
public struct EnvironmentModel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var variables: [KeyValueEntry]
    /// Değeri OAuth2 client credentials ile alınan değişkenler (`{{accessToken}}`).
    public var tokenVariables: [TokenVariable]

    public init(
        id: UUID = UUID(),
        name: String = "Yeni Environment",
        variables: [KeyValueEntry] = [],
        tokenVariables: [TokenVariable] = []
    ) {
        self.id = id
        self.name = name
        self.variables = variables
        self.tokenVariables = tokenVariables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            variables: try container.decode([KeyValueEntry].self, forKey: .variables),
            // Bu alan eklenmeden önce yazılmış dosyalarda yok.
            tokenVariables: try container.decodeIfPresent([TokenVariable].self, forKey: .tokenVariables) ?? []
        )
    }
}

/// İstek koleksiyonu. Diske okunabilir JSON olarak yazılır (git-friendly).
public struct CollectionModel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var requests: [RequestModel]
    /// Koleksiyona konmamış isteklerin tutulduğu özel kap. Arayüzde koleksiyon
    /// olarak değil "Koleksiyonsuz" bölümü olarak görünür; yeniden adlandırılmaz,
    /// silinmez, dışa aktarılmaz, sıralanmaz. Ayrı bir istek listesi yerine
    /// koleksiyon olarak tutulur ki seçme, taşıma, arama, geçmiş gibi tüm
    /// istek işlemleri iki ayrı yol olmadan çalışsın.
    public var isUngrouped: Bool

    public static let ungroupedName = "Koleksiyonsuz"

    public init(id: UUID = UUID(), name: String = "Yeni Koleksiyon", requests: [RequestModel] = [], isUngrouped: Bool = false) {
        self.id = id
        self.name = name
        self.requests = requests
        self.isUngrouped = isUngrouped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            requests: try container.decode([RequestModel].self, forKey: .requests),
            // Bu alan eklenmeden önce yazılmış dosyalarda ve dışa aktarımlarda yok.
            isUngrouped: try container.decodeIfPresent(Bool.self, forKey: .isUngrouped) ?? false
        )
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
    /// Host bazlı TLS ayarları (kurum CA'sı, istemci sertifikası).
    public var tlsProfiles: [TLSProfile]

    public init(
        schemaVersion: Int = 1,
        collections: [CollectionModel] = [],
        environments: [EnvironmentModel] = [],
        activeEnvironmentID: UUID? = nil,
        sentBaselines: [String: RequestModel] = [:],
        tlsProfiles: [TLSProfile] = []
    ) {
        self.schemaVersion = schemaVersion
        self.collections = collections
        self.environments = environments
        self.activeEnvironmentID = activeEnvironmentID
        self.sentBaselines = sentBaselines
        self.tlsProfiles = tlsProfiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            collections: try container.decodeIfPresent([CollectionModel].self, forKey: .collections) ?? [],
            environments: try container.decodeIfPresent([EnvironmentModel].self, forKey: .environments) ?? [],
            activeEnvironmentID: try container.decodeIfPresent(UUID.self, forKey: .activeEnvironmentID),
            // Bu alan eklenmeden önce yazılmış dosyalarda yok.
            sentBaselines: try container.decodeIfPresent([String: RequestModel].self, forKey: .sentBaselines) ?? [:],
            tlsProfiles: try container.decodeIfPresent([TLSProfile].self, forKey: .tlsProfiles) ?? []
        )
    }

    /// Koleksiyonsuz isteklerin kabı; yoksa listenin başına eklenir.
    /// Her zaman en üstte durur: kullanıcı koleksiyonları arasında kaybolmasın.
    public mutating func ensureUngroupedCollection() -> UUID {
        if let existing = collections.first(where: \.isUngrouped) { return existing.id }
        let ungrouped = CollectionModel(name: CollectionModel.ungroupedName, isUngrouped: true)
        collections.insert(ungrouped, at: 0)
        return ungrouped.id
    }

    /// Kullanıcının oluşturduğu koleksiyonlar (koleksiyonsuz kap hariç).
    public var regularCollections: [CollectionModel] {
        collections.filter { !$0.isUngrouped }
    }

    /// Silinmiş isteklerin referans noktalarını atar; dosya şişmesin.
    public mutating func pruneBaselines() {
        let liveIDs = Set(collections.flatMap { $0.requests.map(\.id.uuidString) })
        sentBaselines = sentBaselines.filter { liveIDs.contains($0.key) }
    }
}
