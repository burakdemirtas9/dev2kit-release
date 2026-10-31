import Foundation

/// Kenar çubuğunda bir koleksiyonun satırları: her istek ve, örnekleri
/// açıksa, hemen altında kayıtlı örnekleri.
///
/// Örnekler varsayılan olarak katlıdır (kullanıcı kararı, 2026-10-28): her
/// isteğin örnekleri listeyi kalabalıklaştırıyordu. Açık olanlar `expanded`.
///
/// Neden Core'da: liste sürükle-bırak sırasında GÖRÜNEN satır indeksleri
/// verir; örnek satırları araya girdiği için bu indeksler istek dizisindeki
/// konuma karşılık gelmez. Yanlış çeviri yanlış isteği taşır — kural burada
/// ve testli (`RequestTreeRowsTests`).
/// Satır ağacı için gereken kadarı: kimlik ve örneklerin kimlikleri. Hem tam
/// `RequestModel` hem kenar çubuğu özeti (`SidebarSnapshot.Request`) uyar.
public protocol ExampleListing {
    var id: UUID { get }
    var exampleIDs: [UUID] { get }
}

extension RequestModel: ExampleListing {
    public var exampleIDs: [UUID] { examples.map(\.id) }
}

public enum RequestTreeRows {
    public enum Row: Hashable, Identifiable, Sendable {
        case request(UUID)
        case example(requestID: UUID, exampleID: UUID)

        /// Liste etiketi: istek ya da örnek kimliği.
        public var id: UUID {
            switch self {
            case .request(let id): return id
            case .example(_, let exampleID): return exampleID
            }
        }

        public var isRequest: Bool {
            if case .request = self { return true }
            return false
        }
    }

    /// `expanded`: örnekleri açık istekler; diğerlerinin yalnızca kendi satırı var.
    public static func rows<R: ExampleListing>(for requests: [R], expanded: Set<UUID>) -> [Row] {
        requests.flatMap { request -> [Row] in
            guard expanded.contains(request.id) else { return [.request(request.id)] }
            return [.request(request.id)] + request.exampleIDs.map { .example(requestID: request.id, exampleID: $0) }
        }
    }

    /// Örnek kimliği → sahibi olan istek; görünen satırlar için tek geçişte.
    public static func exampleOwners<R: ExampleListing>(in requests: [R]) -> [UUID: UUID] {
        var owners: [UUID: UUID] = [:]
        for request in requests {
            for exampleID in request.exampleIDs { owners[exampleID] = request.id }
        }
        return owners
    }

    /// Satır indeksleriyle gelen taşımayı istek indekslerine çevirir.
    /// Kaynakta örnek satırı varsa `nil` (örnekler isteğinden ayrılmaz).
    /// Hedef bir isteğin örnekleri arasındaysa taşınan istek o isteğin
    /// ardına gelir; örnekler sahibinin altında kalır.
    public static func requestMove(source: IndexSet, destination: Int, in rows: [Row]) -> (source: IndexSet, destination: Int)? {
        guard !source.isEmpty, source.allSatisfy({ rows.indices.contains($0) && rows[$0].isRequest }) else { return nil }
        func requestIndex(beforeRow row: Int) -> Int {
            rows.prefix(max(0, min(row, rows.count))).filter(\.isRequest).count
        }
        let mapped = IndexSet(source.map { requestIndex(beforeRow: $0) })
        return (mapped, requestIndex(beforeRow: destination))
    }
}
