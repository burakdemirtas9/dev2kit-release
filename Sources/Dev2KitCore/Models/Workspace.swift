import Foundation

/// Bir environment: `{{baseUrl}}` gibi değişkenlerin değer kümesi.
/// Secret'lar burada da durmaz; değişken değeri `{{secret:isim}}` referansı olabilir.
public struct EnvironmentModel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var variables: [KeyValueEntry]
    /// ESKİ BİÇİM: yalnızca okunur, açılışta Token Factory'ye taşınıp boşaltılır
    /// (bkz. `TokenFactoryMigration`, `TokenVariable`).
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
    /// Token Factory: değişkenlere token üreten isteklerin kabı. Koleksiyonsuz
    /// kap ile aynı gerekçeyle koleksiyon olarak tutulur (editör, sekme,
    /// kaydetme, kopyalama tek yoldan çalışsın); arayüzde sol panelin en
    /// altında ayrı bölüm olarak görünür, koleksiyon listesinde değil.
    /// Yeniden adlandırılmaz, silinmez, dışa aktarılmaz, taşıma hedefi olmaz.
    public var isTokenFactory: Bool

    public static let ungroupedName = "Koleksiyonsuz"
    public static let tokenFactoryName = "Token Factory"

    /// Kullanıcının yönetebildiği sıradan bir koleksiyon mu.
    public var isRegular: Bool { !isUngrouped && !isTokenFactory }

    public init(
        id: UUID = UUID(),
        name: String = "Yeni Koleksiyon",
        requests: [RequestModel] = [],
        isUngrouped: Bool = false,
        isTokenFactory: Bool = false
    ) {
        self.id = id
        self.name = name
        self.requests = requests
        self.isUngrouped = isUngrouped
        self.isTokenFactory = isTokenFactory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            requests: try container.decode([RequestModel].self, forKey: .requests),
            // Bu alan eklenmeden önce yazılmış dosyalarda ve dışa aktarımlarda yok.
            isUngrouped: try container.decodeIfPresent(Bool.self, forKey: .isUngrouped) ?? false,
            isTokenFactory: try container.decodeIfPresent(Bool.self, forKey: .isTokenFactory) ?? false
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

    /// Kullanıcının oluşturduğu koleksiyonlar (koleksiyonsuz kap ve Token
    /// Factory hariç).
    public var regularCollections: [CollectionModel] {
        collections.filter(\.isRegular)
    }

    /// Token Factory kabı; yoksa listenin SONUNA eklenir (arayüzde zaten
    /// ayrı bölümde, sıranın kullanıcıya etkisi yok).
    public mutating func ensureTokenFactoryCollection() -> UUID {
        if let existing = collections.first(where: \.isTokenFactory) { return existing.id }
        let factory = CollectionModel(name: CollectionModel.tokenFactoryName, isTokenFactory: true)
        collections.append(factory)
        return factory.id
    }

    /// Token Factory'deki istekler (kap yoksa boş).
    public var tokenFactoryRequests: [RequestModel] {
        collections.first(where: \.isTokenFactory)?.requests ?? []
    }

    /// Silinmiş isteklerin referans noktalarını atar; dosya şişmesin.
    public mutating func pruneBaselines() {
        let liveIDs = Set(collections.flatMap { $0.requests.map(\.id.uuidString) })
        sentBaselines = sentBaselines.filter { liveIDs.contains($0.key) }
    }
}
