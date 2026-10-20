import Foundation

/// Workspace'i diske okunabilir JSON olarak yazar/okur.
/// Konum: ~/Library/Application Support/dev2kit/workspace.json
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

    /// Okunamayan workspace dosyasını aynı klasöre yedekler ve yedeğin adresini döner:
    /// `workspace.bozuk-20261017-224512.json`.
    ///
    /// Neden: okuma başarısız olunca uygulama boş workspace ile açılıyor ve ilk
    /// kayıt bozuk dosyanın ÜZERİNE yazıyordu — uyarı ekrana geldiğinde veri
    /// zaten gitmiş oluyordu. Dosya bozuk olabilir ama içindeki istekler elle
    /// kurtarılabilir; ezilmeden önce kenara alınır. Kopyalanır, taşınmaz:
    /// yedek alınamazsa asıl dosya yerinde kalsın.
    @discardableResult
    public func backUpUnreadableFile(now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let base = "\(stem).bozuk-\(formatter.string(from: now))"
        var backup = directory.appendingPathComponent("\(base).json")
        var attempt = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent("\(base)-\(attempt).json")
            attempt += 1
        }
        try FileManager.default.copyItem(at: fileURL, to: backup)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }

    public func save(_ workspace: WorkspaceModel) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // git diff'leri stabil kalsın
        let data = try encoder.encode(workspace)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Workspace düz metin kimlik bilgisi içerebilir: dizin yalnızca
        // kullanıcıya açık (0700), dosya ve yedeği 0600. Önceden dosya 0644
        // yazılıyordu (güvenlik incelemesi, 2026-10-20). Atomik yazımın geçici
        // dosyası bir an varsayılan izinle oluşur; dizin izni onu da korur.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Atomik yazım: yarım dosya kalmasın.
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
