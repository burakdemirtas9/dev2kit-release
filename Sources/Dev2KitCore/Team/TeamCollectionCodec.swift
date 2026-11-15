import CryptoKit
import Foundation

/// Servisteki `content` ↔ `CollectionModel`.
///
/// Biçim: dev2kit dışa aktarma belgesi (`CollectionPorting.exportData`). Okuma
/// toleranslı: zarf (`{format, version, collection}`), çıplak collection ya da
/// rehberdeki gibi eksik alanlı `{"requests":[{"name","method"}]}` açılır;
/// eksik `id`, `method`, `url` doldurulur, okunamayan istek atlanıp sayılır.
///
/// Kimlikler kararlı: collection kimliği uzak kimlikten türetilir; istek
/// kimliği belgedekiyse korunur, yoksa (uzak kimlik + sıra) türetilir. Böylece
/// her yenilemede açık sekmeler ve seçim yerinde kalır.
public enum TeamCollectionCodec {
    /// Servisin sınırı (rehber: content en çok 5 MB).
    public static let maxContentBytes = 5_000_000

    public struct Decoded: Sendable {
        public let collection: CollectionModel
        public let skippedRequests: Int
    }

    public static func decode(_ content: Data, remoteID: String, name: String) throws -> Decoded {
        guard content.count <= maxContentBytes else { throw TeamError.contentTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: content) as? [String: Any] else {
            throw TeamError.invalidResponse
        }
        let body = (root["collection"] as? [String: Any]) ?? root
        // Tanınmayan biçim boş collection sayılmaz: boş açılıp düzenlenirse
        // kayıt sunucudaki belgenin tamamını ezerdi. Yalnızca boş belge (`{}`)
        // ve `requests` dizisi taşıyan belge açılır.
        let rawRequests: [Any]
        if let list = body["requests"] as? [Any] {
            rawRequests = list
        } else if body["requests"] == nil, root.isEmpty {
            rawRequests = []
        } else {
            throw TeamError.unsupportedContent
        }
        var requests: [RequestModel] = []
        var skipped = 0
        let decoder = JSONDecoder()
        for (index, raw) in rawRequests.enumerated() {
            guard var item = raw as? [String: Any] else { skipped += 1; continue }
            if (item["id"] as? String).flatMap(UUID.init(uuidString:)) == nil {
                item["id"] = stableID(remoteID, "request#\(index)").uuidString
            }
            if item["name"] as? String == nil { item["name"] = "Request \(index + 1)" }
            let method = (item["method"] as? String)?.uppercased() ?? "GET"
            item["method"] = HTTPMethod(rawValue: method) != nil ? method : "GET"
            if item["url"] as? String == nil { item["url"] = "" }
            // Örnekler servise gönderilmez; gelenler de alınmaz (müşteri verisi olabilir).
            item["examples"] = nil
            guard let data = try? JSONSerialization.data(withJSONObject: item),
                  let request = try? decoder.decode(RequestModel.self, from: data) else {
                skipped += 1
                continue
            }
            requests.append(request)
        }
        let collection = CollectionModel(id: stableID(remoteID, "collection"), name: name, requests: requests)
        return Decoded(collection: collection, skippedRequests: skipped)
    }

    /// Kaydedilecek belge: örnekler çıkarılır. Düz metin kimlik bilgisi varsa
    /// kayıt engellenir: collection'ları kurumdaki herkes okur (rehber §8).
    /// Denetim sıkı (`forSharing`): kapalı satırlar ve gövdedeki gizli alanlar
    /// da belgeye yazıldığı için sayılır.
    public static func encode(_ collection: CollectionModel) throws -> Data {
        let credentials = CollectionPorting.plaintextCredentials(in: collection, forSharing: true)
        guard credentials.isEmpty else {
            throw TeamError.plaintextCredentials(credentials.map { "\($0.requestName) (\($0.places.joined(separator: ", ")))" })
        }
        var clean = collection
        clean.requests = collection.requests.map { request in
            var copy = request
            copy.examples = []
            return copy
        }
        let data = try CollectionPorting.exportData(clean)
        guard data.count <= maxContentBytes else { throw TeamError.contentTooLarge }
        return data
    }

    /// Başka bir collection'da zaten kullanılan istek kimliklerini kararlı
    /// biçimde değiştirir (aynı belge iki kurum collection'ına kopyalanmışsa
    /// ya da kullanıcının kendi collection'ından yayınlanmışsa).
    public static func resolvingCollisions(_ collection: CollectionModel, used: Set<UUID>, remoteID: String) -> CollectionModel {
        var copy = collection
        copy.requests = collection.requests.map { request in
            guard used.contains(request.id) else { return request }
            var renamed = request
            renamed.id = stableID(remoteID, "collision#\(request.id.uuidString)")
            return renamed
        }
        return copy
    }

    /// Ad alanlı kararlı UUID (SHA-256'nın ilk 16 baytı, sürüm 5 biçimi).
    static func stableID(_ remoteID: String, _ salt: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("dev2kit.team:\(remoteID):\(salt)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Bir kurum collection'ının uzak bilgisi (yerel collection kimliğine bağlı).
public struct TeamCollectionInfo: Codable, Equatable, Sendable {
    public var summary: TeamCollectionSummary
    /// İçerik bir kez çekildi mi (liste içerik taşımaz; açılınca çekilir).
    public var isLoaded: Bool
    /// Yerelde değişti, sunucuya kaydedilmedi.
    public var isDirty: Bool
    /// Son çekilen içerikte okunamayıp atlanan istek sayısı. Sıfır değilse
    /// yereldeki hal EKSİKTİR: kayıt belgeyi bütün olarak değiştirdiği için
    /// atlananlar sunucudan silinirdi; collection düzenlenemez (`canEdit`).
    public var skippedRequests: Int

    public init(summary: TeamCollectionSummary, isLoaded: Bool = false, isDirty: Bool = false, skippedRequests: Int = 0) {
        self.summary = summary
        self.isLoaded = isLoaded
        self.isDirty = isDirty
        self.skippedRequests = skippedRequests
    }

    private enum CodingKeys: String, CodingKey { case summary, isLoaded, isDirty, skippedRequests }

    /// `skippedRequests` sonradan eklendi: alanı taşımayan önbellek de açılır.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(TeamCollectionSummary.self, forKey: .summary)
        isLoaded = try container.decode(Bool.self, forKey: .isLoaded)
        isDirty = try container.decode(Bool.self, forKey: .isDirty)
        skippedRequests = try container.decodeIfPresent(Int.self, forKey: .skippedRequests) ?? 0
    }
}

/// Kurum collection'larının tek kural kaynağı: hangi yerel collection kurumun,
/// ne yapılabilir. `isRegular` korumalarının yanında kullanılır.
public struct TeamCatalog: Codable, Equatable, Sendable {
    public var entries: [UUID: TeamCollectionInfo] = [:]

    public init(entries: [UUID: TeamCollectionInfo] = [:]) {
        self.entries = entries
    }

    public func isTeam(_ collectionID: UUID) -> Bool { entries[collectionID] != nil }

    /// Kurum collection'ı yalnızca sunucu izin veriyorsa, içeriği çekildiyse ve
    /// içerik eksiksiz okunduysa düzenlenir.
    public func canEdit(_ collectionID: UUID) -> Bool {
        guard let info = entries[collectionID] else { return true }
        return info.summary.canUpdate && info.isLoaded && info.skippedRequests == 0
    }

    public func canDelete(_ collectionID: UUID) -> Bool {
        guard let info = entries[collectionID] else { return true }
        return info.summary.canDelete
    }

    /// Kaydedilmemiş değişikliği olan kurum collection'ları.
    public var dirtyIDs: [UUID] { entries.filter(\.value.isDirty).map(\.key) }
}

extension WorkspaceModel {
    /// Diske yazılan hal: kurum collection'ları workspace kaydına, yedeğe ve
    /// "son gönderilen"lere girmez (kaynakları servis; önbellekleri ayrı).
    public func excludingCollections(_ ids: Set<UUID>) -> WorkspaceModel {
        guard !ids.isEmpty else { return self }
        var copy = self
        let removed = Set(collections.filter { ids.contains($0.id) }.flatMap { $0.requests.map(\.id.uuidString) })
        copy.collections.removeAll { ids.contains($0.id) }
        copy.sentBaselines = sentBaselines.filter { !removed.contains($0.key) }
        return copy
    }
}
