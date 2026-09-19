import Foundation
import Security

/// Secret depolama soyutlaması. Prod'da Keychain, testlerde in-memory kullanılır.
public protocol SecretStore: Sendable {
    func setSecret(_ value: String, forName name: String) throws
    func secret(forName name: String) throws -> String?
    func deleteSecret(forName name: String) throws
    func listSecretNames() throws -> [String]
}

public enum SecretStoreError: Error, LocalizedError {
    case keychainStatus(OSStatus)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "bilinmeyen hata"
            return "Keychain hatası (\(status)): \(message)"
        case .encodingFailed:
            return "Secret değeri kodlanamadı."
        }
    }
}

/// macOS Keychain tabanlı secret deposu.
/// Tüm kayıtlar tek bir service adı altında generic password olarak tutulur;
/// secret adı `account` alanına yazılır. Değerler asla diske/log'a düşmez.
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.secora.secrets") {
        self.service = service
    }

    public func setSecret(_ value: String, forName name: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecretStoreError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        // Varsa güncelle, yoksa ekle (upsert).
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Sadece cihaz kilidi açıkken erişilebilir; iCloud Keychain'e senkronlanmaz.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.keychainStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw SecretStoreError.keychainStatus(updateStatus)
        }
    }

    public func secret(forName name: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError.keychainStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteSecret(forName name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychainStatus(status)
        }
    }

    public func listSecretNames() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw SecretStoreError.keychainStatus(status)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

/// Test ve preview'lar için in-memory secret deposu.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(initial: [String: String] = [:]) {
        self.storage = initial
    }

    public func setSecret(_ value: String, forName name: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[name] = value
    }

    public func secret(forName name: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[name]
    }

    public func deleteSecret(forName name: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: name)
    }

    public func listSecretNames() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.keys.sorted()
    }
}
