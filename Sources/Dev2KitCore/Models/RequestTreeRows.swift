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
        /// Klasör başlığı (`RequestFolders`): kararlı kimlik, yol, içindeki
        /// (alt klasörler dahil) istek sayısı.
        case folder(id: UUID, path: [String], count: Int)

        /// Liste etiketi: istek, örnek ya da klasör satırının kimliği.
        public var id: UUID {
            switch self {
            case .request(let id): return id
            case .example(_, let exampleID): return exampleID
            case .folder(let id, _, _): return id
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

    /// Klasörlü satır listesi. `requests` gösterim sırasında olmalı
    /// (`RequestFolders.canonical`; kenar çubuğu özeti öyle verir). Yol
    /// değiştikçe araya klasör başlıkları girer; `collapsedFolders`'taki bir
    /// klasörün (kimliği `folderID` ile) altındaki satırlar listelenmez.
    /// Klasör yoksa sonuç `rows(for:expanded:)` ile aynıdır.
    public static func rows<R: ExampleListing & FolderPlaced>(
        for requests: [R], expanded: Set<UUID>, collapsedFolders: Set<UUID>, folderID: ([String]) -> UUID
    ) -> [Row] {
        guard requests.contains(where: { !$0.folder.isEmpty }) else { return rows(for: requests, expanded: expanded) }
        var counts: [[String]: Int] = [:]
        for request in requests {
            for depth in 0..<request.folder.count { counts[Array(request.folder.prefix(depth + 1)), default: 0] += 1 }
        }
        var result: [Row] = []
        var current: [String] = []
        // Katlı klasörün yolu: altındaki her şey atlanır.
        var hidden: [String]?
        for request in requests {
            if request.folder != current {
                let shared = zip(current, request.folder).prefix { $0 == $1 }.count
                for depth in shared..<request.folder.count {
                    let path = Array(request.folder.prefix(depth + 1))
                    if let hiddenPath = hidden, path.starts(with: hiddenPath) { continue }
                    hidden = nil
                    let id = folderID(path)
                    result.append(.folder(id: id, path: path, count: counts[path] ?? 0))
                    if collapsedFolders.contains(id) { hidden = path }
                }
                current = request.folder
                if let hiddenPath = hidden, !current.starts(with: hiddenPath) { hidden = nil }
            }
            if hidden != nil { continue }
            result.append(.request(request.id))
            if expanded.contains(request.id) {
                result.append(contentsOf: request.exampleIDs.map { .example(requestID: request.id, exampleID: $0) })
            }
        }
        return result
    }

    /// Sürükle-bırakın sonucu: hangi istekler, hangi klasöre, hangi isteğin önüne.
    public struct Placement: Equatable, Sendable {
        public let ids: Set<UUID>
        public let folder: [String]
        /// `nil`: klasörün sonuna.
        public let before: UUID?
    }

    /// Satır indeksleriyle gelen taşımayı yerleşime çevirir (`RequestFolders.placing`).
    /// Kaynakta istek dışı satır varsa `nil` (örnek ve klasör sürüklenmez).
    /// Hedef klasör, bırakılan yerin hemen üstündeki satırdan okunur: klasör
    /// başlığıysa o klasör, istek ya da örnekse onun klasörü, en baştaysa kök.
    /// Sıra: bırakılan yerden sonraki ilk istek aynı klasördeyse onun önü,
    /// değilse klasörün sonu. Katlı klasörlerdeki gizli istekler hesabı
    /// bozmaz: indeks değil kimlik kullanılır.
    public static func placement(source: IndexSet, destination: Int, in rows: [Row],
                                 folderOf: (UUID) -> [String]) -> Placement? {
        var ids = Set<UUID>()
        for index in source {
            guard rows.indices.contains(index), case .request(let id) = rows[index] else { return nil }
            ids.insert(id)
        }
        guard !ids.isEmpty else { return nil }
        let clamped = max(0, min(destination, rows.count))
        let folder: [String]
        if clamped == 0 {
            folder = []
        } else {
            switch rows[clamped - 1] {
            case .folder(_, let path, _): folder = path
            case .request(let id): folder = folderOf(id)
            case .example(let requestID, _): folder = folderOf(requestID)
            }
        }
        var before: UUID?
        for row in rows[clamped...] {
            if case .folder = row { break }
            if case .request(let id) = row, !ids.contains(id) {
                if folderOf(id) == folder { before = id }
                break
            }
        }
        return Placement(ids: ids, folder: folder, before: before)
    }

    /// Örnek kimliği → sahibi olan istek; görünen satırlar için tek geçişte.
    public static func exampleOwners<R: ExampleListing>(in requests: [R]) -> [UUID: UUID] {
        var owners: [UUID: UUID] = [:]
        for request in requests {
            for exampleID in request.exampleIDs { owners[exampleID] = request.id }
        }
        return owners
    }
}
