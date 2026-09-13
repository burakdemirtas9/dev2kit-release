import CryptoKit
import Foundation

/// AES-GCM ile şifrelenmiş JSON dosyası.
///
/// Anahtar, veri dosyasının yanında ayrı ve yalnızca kullanıcının okuyabildiği
/// (0600) bir dosyada durur. Bu model dosyanın yanlışlıkla paylaşılmasına
/// (git, yedek, senkron klasörü) karşı korur; makineye erişen bir saldırgana
/// karşı değil. Secret vault ve geçmiş kaydı aynı mekanizmayı kullanır ki
/// ikisi ayrışıp biri korumasız kalmasın.
struct EncryptedJSONFile<Value: Codable>: Sendable {
    let fileURL: URL
    let keyURL: URL

    enum FileError: Error, LocalizedError {
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .encodingFailed: return "Şifreli dosya yazılamadı."
            }
        }
    }

    func load(fallback: Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return fallback }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: fileURL))
        let plain = try AES.GCM.open(sealed, using: loadKey())
        return try JSONDecoder().decode(Value.self, from: plain)
    }

    func save(_ value: Value) throws {
        let plain = try JSONEncoder().encode(value)
        let sealed = try AES.GCM.seal(plain, using: loadKey())
        guard let combined = sealed.combined else { throw FileError.encodingFailed }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try combined.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func deleteFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func loadKey() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try FileManager.default.createDirectory(
            at: keyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }
}
