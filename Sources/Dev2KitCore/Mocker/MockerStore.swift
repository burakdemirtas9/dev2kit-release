import Foundation

/// Mock tanımlarının dosyası: `<veri dizini>/mocker/mocks.json` (0600,
/// atomik yazım). Workspace'in çok dosyalı deposundan ayrı: tanımlar API
/// Client verisiyle karışmaz, bozulursa yalnızca bu dosya etkilenir.
///
/// Okunamayan dosya SİLİNMEZ: yanına `mocks.corrupt-<zaman>.json` olarak
/// taşınır, boş tanımla açılır ve kullanıcıya söylenir.
public struct MockerStore: Sendable {
    public let url: URL

    public init(root: URL) {
        url = root.appendingPathComponent("mocker", isDirectory: true).appendingPathComponent("mocks.json")
    }

    public enum LoadResult: Equatable, Sendable {
        case loaded(MockerDocument)
        case missing
        /// Okunamadı; dosya bu adla kenara alındı.
        case corrupt(movedTo: String)
    }

    public func load() -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        do {
            return .loaded(try JSONDecoder().decode(MockerDocument.self, from: data))
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = url.deletingLastPathComponent().appendingPathComponent("mocks.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return .corrupt(movedTo: aside.lastPathComponent)
        }
    }

    public func encode(_ document: MockerDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    public func save(_ document: MockerDocument) throws {
        try AtomicFile.write(try encode(document), to: url)
    }
}
