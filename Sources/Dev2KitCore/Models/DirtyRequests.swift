import Foundation

/// "Son gönderildiği halden farklı" işaretinin kuralı.
///
/// Yalnızca gönderilmiş (referans noktası olan) istekler kirli olabilir:
/// hiç gönderilmemiş istekte karşılaştırılacak bir "test edilmiş hal" yoktur.
public enum DirtyRequests {
    /// Tüm koleksiyonları TEK geçişte tarar. Satır başına çağrılmak üzere
    /// tasarlanmadı: view gövdesinde bir kez hesaplanıp dağıtılır.
    public static func ids(in collections: [CollectionModel], baselines: [String: RequestModel]) -> Set<UUID> {
        guard !baselines.isEmpty else { return [] }
        var dirty: Set<UUID> = []
        for collection in collections {
            for request in collection.requests {
                guard let baseline = baselines[request.id.uuidString] else { continue }
                if !request.isFunctionallyEqual(to: baseline) { dirty.insert(request.id) }
            }
        }
        return dirty
    }

    /// Tek istek için aynı kural.
    public static func isDirty(_ request: RequestModel, baselines: [String: RequestModel]) -> Bool {
        guard let baseline = baselines[request.id.uuidString] else { return false }
        return !request.isFunctionallyEqual(to: baseline)
    }
}
