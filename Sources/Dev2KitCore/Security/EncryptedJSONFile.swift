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

    enum FileError: Error, LocalizedError, Equatable {
        case encodingFailed
        /// Anahtar dosyası var ama okunamıyor ya da boyu yanlış.
        case keyUnreadable(path: String)
        /// Şifreli dosya var, anahtarı yok: yeni anahtar onu açamaz.
        case keyMissing(path: String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return L10n.t("crypto.writeFailed")
            case .keyUnreadable(let path):
                return L10n.t("crypto.keyUnreadable", path)
            case .keyMissing(let path):
                return L10n.t("crypto.keyMissing", path)
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
        // 0600 geçici dosya → fsync → rename (bkz. `AtomicFile`).
        try AtomicFile.write(combined, to: fileURL)
    }

    func deleteFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Anahtarı okur; YALNIZCA hiç anahtar ve hiç şifreli veri yoksa yenisini üretir.
    ///
    /// Önceden okuma `try?` ile yapılıyordu: anahtar dosyası bir kez
    /// okunamayınca (izin değişikliği, EDR kilidi, bozulma) yeni anahtar
    /// üretilip eskisinin ÜZERİNE yazılıyordu — vault ve geçmiş bir daha
    /// açılamaz hale geliyordu, sessizce ve geri dönüşsüz. Artık okunamayan
    /// anahtar hata verir; veri ve anahtar dosyası olduğu gibi kalır.
    private func loadKey() throws -> SymmetricKey {
        let manager = FileManager.default
        if manager.fileExists(atPath: keyURL.path) {
            guard let data = try? Data(contentsOf: keyURL), data.count == 32 else {
                throw FileError.keyUnreadable(path: keyURL.path)
            }
            return SymmetricKey(data: data)
        }
        guard !manager.fileExists(atPath: fileURL.path) else {
            throw FileError.keyMissing(path: keyURL.path)
        }
        let key = SymmetricKey(size: .bits256)
        try writeKey(key.withUnsafeBytes { Data($0) })
        return key
    }

    /// Anahtarı baştan 0600 izinle ve atomik yazar.
    ///
    /// Önceden önce varsayılan izinle (0644) yazılıp sonra 0600'e çekiliyordu;
    /// arada başka kullanıcıların okuyabildiği bir an vardı. Geçici dosya
    /// 0600 ile oluşturulur ve `rename(2)` ile yerine konur: yarım anahtar
    /// dosyası da kalmaz.
    private func writeKey(_ data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = keyURL.deletingLastPathComponent()
            .appendingPathComponent(".\(keyURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, keyURL.path) == 0 else {
            let code = errno
            try? manager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
