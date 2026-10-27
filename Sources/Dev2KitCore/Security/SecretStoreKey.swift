import Foundation

/// Şifreleme anahtarını bir secret deposu kaydında (Base64) tutar.
///
/// Neden: dosyadaki anahtar şifreli verinin yanında durur; dizini (yedek,
/// kopya) ele geçiren ikisini birlikte alır. Developer ID ile imzalı sürümde
/// geçmiş anahtarı Keychain'dedir: uygulama imzasıyla tanındığı için soru
/// çıkmaz, başka bir uygulama okumak isterse macOS sorar.
///
/// Anahtar ilk okumadan sonra bellekte tutulur: geçmişin her yazımında
/// Keychain'e gidilmesin.
public final class SecretStoreKey: @unchecked Sendable {
    /// Anahtarların Keychain servisi. Secret'lardan (`com.dev2kit.secrets`)
    /// ayrı: anahtar vault listesinde görünmesin, vault'tan silinemesin.
    public static let keychainService = "com.dev2kit.keys"

    /// Keychain'deki anahtar.
    public static func keychain(name: String) -> SecretStoreKey {
        SecretStoreKey(store: KeychainSecretStore(service: keychainService), name: name)
    }

    private let store: SecretStore
    private let name: String
    private let lock = NSLock()
    private var cached: Data?

    public init(store: SecretStore, name: String) {
        self.store = store
        self.name = name
    }

    /// Hata mesajlarında gösterilen yer.
    var location: String { "Keychain: \(Self.keychainService)/\(name)" }

    /// Kayıtlı anahtar; yoksa `nil`. Bozuk kayıt boş veri döner: çağıran
    /// boyu denetler ve yeni anahtar üretmez. `fresh` belleği atlar
    /// (taşımada yazılanı gerçekten geri okumak için).
    func load(fresh: Bool = false) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if !fresh, let cached { return cached }
        guard let text = try store.secret(forName: name) else { return nil }
        let data = Data(base64Encoded: text) ?? Data()
        if data.count == 32 { cached = data }
        return data
    }

    func save(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        try store.setSecret(data.base64EncodedString(), forName: name)
        cached = data
    }
}
