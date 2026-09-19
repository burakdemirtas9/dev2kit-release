import Foundation

/// Workspace'i diske okunabilir JSON olarak yazar/okur.
/// Konum: ~/Library/Application Support/Secora/workspace.json
/// Secret'lar bu dosyada asla yer almaz (yalnızca {{secret:...}} referansları).
public struct WorkspaceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.supportDirectory.appendingPathComponent("workspace.json")
    }

    public func load() throws -> WorkspaceModel {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return WorkspaceModel()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(WorkspaceModel.self, from: data)
    }

    public func save(_ workspace: WorkspaceModel) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // git diff'leri stabil kalsın
        let data = try encoder.encode(workspace)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomik yazım: yarım dosya kalmasın.
        try data.write(to: fileURL, options: .atomic)
    }
}
