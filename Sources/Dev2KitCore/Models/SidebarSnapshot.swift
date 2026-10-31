import Foundation

/// Kenar çubuğunun gösterdiği kadarı: koleksiyon ve istek kimliği, adı,
/// metodu, kayıtlı örnekler ve "son gönderilenden farklı" işareti.
///
/// Neden (2026-11-01, ölçüldü): kenar çubuğu workspace'in tamamına bağlıydı;
/// bir header'a tek harf yazınca 2000 satırlık liste yeniden kurulup SwiftUI
/// tarafından karşılaştırılıyordu (`OutlineListCoordinator.diffRows`, yazma
/// başına ana iş parçacığının ~%62'si). Bu özet header, gövde, auth, URL ya
/// da seçenek değişince AYNI kalır; kenar çubuğu yalnızca gösterdiği şey
/// değişince yeniden çizilir.
///
/// URL özette yok: arama URL'de de aradığı için arama açıkken eşleşme tam
/// modellerden bulunur (`matching(_:)`), görünen bilgi yine buradan gelir.
public struct SidebarSnapshot: Equatable, Sendable {
    public struct Example: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let statusCode: Int
    }

    public struct Request: Equatable, Sendable, Identifiable, ExampleListing {
        public let id: UUID
        public let name: String
        public let method: HTTPMethod
        public let examples: [Example]

        public var exampleIDs: [UUID] { examples.map(\.id) }
    }

    public struct Collection: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let isUngrouped: Bool
        public let isTokenFactory: Bool
        /// Gösterilen istekler: arama açıkken yalnızca eşleşenler.
        public let requests: [Request]
        /// Koleksiyondaki istek sayısı (aramadan bağımsız).
        public let totalRequests: Int

        public var isRegular: Bool { !isUngrouped && !isTokenFactory }

        /// `CollectionModel.displayName` ile aynı; dil anında değişebildiği
        /// için özete yazılmaz, okunurken çevrilir.
        public var displayName: String {
            isUngrouped ? L10n.t("collection.ungrouped") : name
        }

        func showing(_ requests: [Request]) -> Collection {
            Collection(id: id, name: name, isUngrouped: isUngrouped, isTokenFactory: isTokenFactory,
                       requests: requests, totalRequests: totalRequests)
        }
    }

    public private(set) var collections: [Collection]
    /// Son gönderildiği halden farklı istekler (`DirtyRequests`).
    public private(set) var dirty: Set<UUID>

    public init() {
        collections = []
        dirty = []
    }

    public init(workspace: WorkspaceModel) {
        collections = workspace.collections.map { collection in
            Collection(
                id: collection.id,
                name: collection.name,
                isUngrouped: collection.isUngrouped,
                isTokenFactory: collection.isTokenFactory,
                requests: collection.requests.map { request in
                    Request(id: request.id, name: request.name, method: request.method,
                            examples: request.examples.map { Example(id: $0.id, name: $0.name, statusCode: $0.statusCode) })
                },
                totalRequests: collection.requests.count
            )
        }
        dirty = DirtyRequests.ids(in: workspace.collections, baselines: workspace.sentBaselines)
    }

    /// İstek adı (silme onayı gibi yerler; workspace okumadan).
    public func requestName(_ id: UUID) -> String? {
        for collection in collections {
            if let request = collection.requests.first(where: { $0.id == id }) { return request.name }
        }
        return nil
    }

    /// Arama sonucunu özete çevirir: koleksiyon sırası ve eşleşen isteklerin
    /// sırası aramadan, gösterilen bilgi özetten.
    public func matching(_ matches: [RequestSearch.Match]) -> [Collection] {
        let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return matches.compactMap { match in
            guard let collection = byID[match.collection.id] else { return nil }
            let requestsByID = Dictionary(collection.requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return collection.showing(match.requests.compactMap { requestsByID[$0.id] })
        }
    }
}
