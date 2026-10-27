import CryptoKit
import Foundation

/// `EncryptedJSONFile` anahtarının yeri.
enum EncryptionKeySource: Sendable {
    /// Verinin yanında, yalnızca kullanıcının okuyabildiği (0600) dosya.
    case file(URL)
    /// Secret deposundaki kayıt: Developer ID ile imzalı sürümde Keychain.
    case stored(SecretStoreKey)
}

/// AES-GCM ile şifrelenmiş JSON dosyası.
///
/// Anahtar dosyadaysa veri dosyasının yanında ayrı ve yalnızca kullanıcının
/// okuyabildiği (0600) bir dosyada durur. Bu model dosyanın yanlışlıkla
/// paylaşılmasına (git, senkron klasörü) karşı korur; makineye erişen bir
/// saldırgana ya da aynı kullanıcıyla çalışan bir sürece karşı değil.
/// Anahtar Keychain'deyse dizini ele geçiren anahtarı bulamaz.
/// Secret vault ve geçmiş kaydı aynı mekanizmayı kullanır ki ikisi ayrışıp
/// biri korumasız kalmasın.
struct EncryptedJSONFile<Value: Codable>: Sendable {
    let fileURL: URL
    let key: EncryptionKeySource

    init(fileURL: URL, key: EncryptionKeySource) {
        self.fileURL = fileURL
        self.key = key
    }

    init(fileURL: URL, keyURL: URL) {
        self.init(fileURL: fileURL, key: .file(keyURL))
    }

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
        // 0600 geçici dosya → fsync → rename (bkz. `AtomicFile`). Yedeğe
        // gitmez: anahtar dosyadaysa ikisi aynı yedekte buluşmasın.
        try AtomicFile.write(combined, to: fileURL, excludedFromBackup: true)
    }

    /// Var olan veri ve anahtar dosyasını yedek dışı işaretler: önceki
    /// sürümün yazdıkları yeniden yazılana kadar beklemesin.
    func excludeExistingFromBackup() {
        var urls = [fileURL]
        if case .file(let keyURL) = key { urls.append(keyURL) }
        BackupExclusion.excludeExisting(urls)
    }

    func deleteFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Anahtarın alınabildiğini doğrular; veriyi okumaz.
    ///
    /// Okuyan taraf anahtar sorununu bozuk veriden ayırabilsin diye: anahtar
    /// gelmiyorsa veri kenara alınmamalı, üzerine yazılmamalı.
    func requireKey() throws {
        _ = try loadKey()
    }

    /// Anahtarı okur; YALNIZCA hiç anahtar ve hiç şifreli veri yoksa yenisini üretir.
    ///
    /// Önceden okuma `try?` ile yapılıyordu: anahtar dosyası bir kez
    /// okunamayınca (izin değişikliği, EDR kilidi, bozulma) yeni anahtar
    /// üretilip eskisinin ÜZERİNE yazılıyordu — vault ve geçmiş bir daha
    /// açılamaz hale geliyordu, sessizce ve geri dönüşsüz. Artık okunamayan
    /// anahtar hata verir; veri ve anahtar olduğu gibi kalır.
    private func loadKey() throws -> SymmetricKey {
        if let data = try storedKey() {
            guard data.count == 32 else { throw FileError.keyUnreadable(path: keyLocation) }
            return SymmetricKey(data: data)
        }
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FileError.keyMissing(path: keyLocation)
        }
        let newKey = SymmetricKey(size: .bits256)
        let data = newKey.withUnsafeBytes { Data($0) }
        switch key {
        case .file(let url): try writeKey(data, to: url)
        case .stored(let store): try store.save(data)
        }
        return newKey
    }

    /// Kayıtlı anahtar; hiç yoksa `nil`. Var ama okunamıyorsa hata.
    private func storedKey() throws -> Data? {
        switch key {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard let data = try? Data(contentsOf: url) else { throw FileError.keyUnreadable(path: url.path) }
            return data
        case .stored(let store):
            return try store.load()
        }
    }

    /// Hata mesajlarında gösterilen yer.
    private var keyLocation: String {
        switch key {
        case .file(let url): return url.path
        case .stored(let store): return store.location
        }
    }

    /// Anahtarı baştan 0600 izinle ve atomik yazar.
    ///
    /// Önceden önce varsayılan izinle (0644) yazılıp sonra 0600'e çekiliyordu;
    /// arada başka kullanıcıların okuyabildiği bir an vardı. Geçici dosya
    /// 0600 ile oluşturulur ve `rename(2)` ile yerine konur: yarım anahtar
    /// dosyası da kalmaz.
    private func writeKey(_ data: Data, to keyURL: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = keyURL.deletingLastPathComponent()
            .appendingPathComponent(".\(keyURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        BackupExclusion.exclude(temporary)
        guard rename(temporary.path, keyURL.path) == 0 else {
            let code = errno
            try? manager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
