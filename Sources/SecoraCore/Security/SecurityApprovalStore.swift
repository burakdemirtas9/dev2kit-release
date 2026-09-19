import Foundation

/// Kullanıcının "Yine de gönder" ile onayladığı uyarılar.
///
/// Anahtarlar durum + host (+ secret ADI) içerir, secret DEĞERİ asla içermez.
/// Yine de hangi secret'ın hangi host'a gittiğini gösterdiği için dosya 0600.
/// Konum: ~/Library/Application Support/Secora/security-approvals.json
public struct SecurityApprovalStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.supportDirectory.appendingPathComponent("security-approvals.json")
    }

    /// Okunamayan dosya boş küme sayılır: en kötü ihtimalle uyarılar yeniden
    /// sorulur, hiçbir uyarı sessizce geçilmez.
    public func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(keys)
    }

    public func approve(_ keys: some Sequence<String>) throws {
        try save(load().union(keys))
    }

    public func reset() throws {
        try save([])
    }

    private func save(_ keys: Set<String>) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(keys.sorted())
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
