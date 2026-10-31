import Foundation

/// İstek kimliği → workspace'teki konumu (koleksiyon, istek dizini).
///
/// Neden (2026-11-01): `locateRequest` her çağrıda bütün koleksiyonları
/// baştan tarıyordu; istek editörünün bağlaması her okuma ve yazmada onu
/// çağırdığı için bir çizimde onlarca tarama oluyordu (2000 istekte bağlama
/// okuma 344 µs, yazma 710 µs; ölçüldü, Debug). Sekme çubuğundaki aynı
/// kalıp sürüklemede çizimin yarısını yiyordu.
///
/// Güncel tutma kuralı: tablo değişiklik bildirimiyle değil, OKURKEN
/// doğrulanır. Kayıtlı konum dizin sınırında ve o konumdaki isteğin kimliği
/// aynıysa doğrudur (O(1)); değilse (taşındı, silindi, araya eklendi) tablo
/// tek geçişte yeniden kurulur. Workspace'i değiştiren onlarca yerden hiçbiri
/// tabloyu bilmek zorunda değil ve bayat konum hiç dönmez.
///
/// Aynı kimlik iki kez varsa (geçersiz veri) yeniden kurulumda ilki alınır
/// (eski taramayla aynı); doğrulanan kayıtlı konum ise ikincisini de
/// gösterebilir.
public struct RequestLocator: Sendable {
    public struct Location: Equatable, Sendable {
        public let collection: Int
        public let request: Int

        public init(collection: Int, request: Int) {
            self.collection = collection
            self.request = request
        }
    }

    private var locations: [UUID: Location] = [:]
    /// Testler için: kaç kez yeniden kuruldu.
    public private(set) var rebuildCount = 0

    public init() {}

    public mutating func locate(_ id: UUID, in collections: [CollectionModel]) -> Location? {
        if let cached = locations[id], Self.isValid(cached, for: id, in: collections) {
            return cached
        }
        rebuild(collections)
        return locations[id]
    }

    private mutating func rebuild(_ collections: [CollectionModel]) {
        rebuildCount += 1
        locations.removeAll(keepingCapacity: true)
        for collectionIndex in collections.indices {
            let requests = collections[collectionIndex].requests
            for requestIndex in requests.indices {
                let id = requests[requestIndex].id
                if locations[id] == nil {
                    locations[id] = Location(collection: collectionIndex, request: requestIndex)
                }
            }
        }
    }

    private static func isValid(_ location: Location, for id: UUID, in collections: [CollectionModel]) -> Bool {
        collections.indices.contains(location.collection)
            && collections[location.collection].requests.indices.contains(location.request)
            && collections[location.collection].requests[location.request].id == id
    }
}
