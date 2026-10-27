import CryptoKit
import Foundation

/// Tek dosyanın atomik yazımı ve okuması.
///
/// Yazım: aynı dizinde 0600 izinli geçici dosya → `fsync` → `rename(2)`.
/// Yarıda kesilen yazım (çökme, disk dolu) eski dosyayı bozmaz: ya eski ya
/// yeni içerik görünür. `Data.write(options: .atomic)` diske boşaltmadığı
/// için (fsync yok) elektrik kesintisinde boş dosya bırakabiliyordu.
///
/// Bu yalnızca DOSYA BAŞINA atomikliktir; birden çok dosyalı işlemin
/// atomikliği `StoreJournal` ile sağlanır.
public enum AtomicFile {
    /// `excludedFromBackup`: yedek dışı işareti geçici dosyaya, yerine
    /// konmadan önce yazılır; yeni dosya hiçbir an işaretsiz görünmez
    /// (bkz. `BackupExclusion`).
    public static func write(_ data: Data, to url: URL, excludedFromBackup: Bool = false) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        if excludedFromBackup { BackupExclusion.exclude(temporary) }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? manager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// İçeriğin özeti: manifest'te dosyanın hangi sürümünün geçerli olduğunu
    /// doğrulamak için (yarım kalan işlem, dışarıdan bozulma).
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Yarıda kalmış yazımların geçici dosyalarını siler (açılışta).
    static func removeLeftovers(in directory: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(".") && name.hasSuffix(".tmp") {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
