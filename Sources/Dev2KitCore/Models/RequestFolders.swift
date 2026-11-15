import CryptoKit
import Foundation

/// Bir klasöre yerleşebilen şey: tam `RequestModel` ve kenar çubuğu özeti.
public protocol FolderPlaced {
    var folder: [String] { get }
}

extension RequestModel: FolderPlaced {}

/// Collection içi klasörler (2026-11-15).
///
/// Klasör ayrı bir nesne DEĞİL: her isteğin isteğe bağlı bir klasör yolu var
/// (`RequestModel.folder`, ör. `["Kullanıcı", "Yönetim"]`). Collection yine
/// düz bir istek dizisi; istek bulma, sekmeler, arama, kayıt, kurum
/// collection'ları ve Token Factory olduğu gibi çalışır. Klasörsüz
/// collection'da hiçbir şey değişmez ve diskteki dosyalar aynı kalır.
///
/// Sonuçları: boş klasör olamaz (içinde istek olmayan klasör yoktur);
/// klasörü yeniden adlandırmak içindeki isteklerin yolunu değiştirmektir.
///
/// Gösterim sırası (`canonical`): her düzeyde önce o düzeyin istekleri
/// (dizideki sırayla), sonra alt klasörler (ilk görüldükleri sırayla).
public enum RequestFolders {
    public static let maxDepth = 10
    public static let maxNameLength = 120

    /// Yolu temizler: boşluklar kırpılır, boş parçalar atılır, ad ve derinlik
    /// sınırlanır (içe aktarılan dosya 100 düzey, 1000 karakterlik adlar
    /// taşıyabilir; yol her isteğe yazılır). Sınırın altındaki düzeyler son
    /// izinli klasörde toplanır.
    public static func sanitized(_ path: [String]) -> [String] {
        path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxDepth)
            .map { $0.count > maxNameLength ? String($0.prefix(maxNameLength)) + "…" : $0 }
    }

    /// İstekleri gösterim sırasına dizer. Klasör yoksa dizi aynen döner.
    public static func canonical<R: FolderPlaced>(_ requests: [R]) -> [R] {
        guard requests.contains(where: { !$0.folder.isEmpty }) else { return requests }
        let root = FolderNode()
        for (index, request) in requests.enumerated() {
            var node = root
            for name in request.folder {
                if let child = node.children[name] {
                    node = child
                } else {
                    let child = FolderNode()
                    node.children[name] = child
                    node.order.append(name)
                    node = child
                }
            }
            node.requests.append(index)
        }
        var result: [R] = []
        result.reserveCapacity(requests.count)
        // Derinlik `maxDepth` ile sınırlı olmayabilir (eski/elle yazılmış
        // veri); yığın yerine açık liste.
        var stack: [FolderNode] = [root]
        while let node = stack.popLast() {
            result.append(contentsOf: node.requests.map { requests[$0] })
            stack.append(contentsOf: node.order.reversed().compactMap { node.children[$0] })
        }
        return result
    }

    /// Collection'daki tüm klasör yolları (ara düzeyler dahil), gösterim sırasıyla.
    public static func paths<R: FolderPlaced>(in requests: [R]) -> [[String]] {
        var seen = Set<[String]>()
        var result: [[String]] = []
        for request in canonical(requests) {
            for depth in 1...max(1, request.folder.count) where depth <= request.folder.count {
                let path = Array(request.folder.prefix(depth))
                if seen.insert(path).inserted { result.append(path) }
            }
        }
        return result
    }

    /// Klasörü yeniden adlandırır: yolu `path` ile başlayan her isteğin o
    /// parçası değişir. Yeni ad aynı düzeyde varsa iki klasör birleşir.
    public static func renaming(_ path: [String], to newName: String, in requests: [RequestModel]) -> [RequestModel] {
        guard let name = sanitized([newName]).first, !path.isEmpty else { return requests }
        return requests.map { request in
            guard request.folder.starts(with: path) else { return request }
            var copy = request
            copy.folder[path.count - 1] = name
            return copy
        }
    }

    /// Klasörü kaldırır, içindekiler kalır: istekler ve alt klasörler bir üst düzeye çıkar.
    public static func removing(_ path: [String], in requests: [RequestModel]) -> [RequestModel] {
        guard !path.isEmpty else { return requests }
        return requests.map { request in
            guard request.folder.starts(with: path) else { return request }
            var copy = request
            copy.folder.remove(at: path.count - 1)
            return copy
        }
    }

    /// İstekleri bir klasöre yerleştirir ve diziyi gösterim sırasına getirir.
    /// `anchor` verilmişse ve o da aynı klasördeyse taşınanlar onun önüne,
    /// yoksa klasörün sonuna gelir. Taşınanların kendi aralarındaki sıra korunur.
    public static func placing(_ ids: Set<UUID>, in folder: [String], before anchor: UUID?,
                               requests: [RequestModel]) -> [RequestModel] {
        let path = sanitized(folder)
        var moved = requests.filter { ids.contains($0.id) }
        guard !moved.isEmpty else { return requests }
        for index in moved.indices { moved[index].folder = path }
        var rest = requests.filter { !ids.contains($0.id) }
        if let anchor, let index = rest.firstIndex(where: { $0.id == anchor }), rest[index].folder == path {
            rest.insert(contentsOf: moved, at: index)
        } else {
            rest.append(contentsOf: moved)
        }
        return canonical(rest)
    }

    /// Klasör satırının kararlı kimliği (liste etiketi, katlama tercihi).
    public static func rowID(collection: UUID, path: [String]) -> UUID {
        let text = "dev2kit.folder:\(collection.uuidString):" + path.joined(separator: "\u{1F}")
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// `RequestFolders.canonical` için klasör düğümü: bu düzeydeki isteklerin
/// dizideki konumları ve alt klasörler (ilk görülme sırasıyla).
private final class FolderNode {
    var requests: [Int] = []
    var order: [String] = []
    var children: [String: FolderNode] = [:]
}
