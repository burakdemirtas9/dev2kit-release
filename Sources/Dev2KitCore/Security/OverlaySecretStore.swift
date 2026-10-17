import Foundation

/// Asıl secret deposunun önüne bellekteki değerleri koyar (Token Factory
/// token'ları gönderim anında böyle verilir). Yazma ve silme
/// asıl depoya gider; bellekteki değerler hiçbir zaman diske yazılmaz.
public final class OverlaySecretStore: SecretStore, @unchecked Sendable {
    private let base: SecretStore
    private let overrides: [String: String]

    public init(base: SecretStore, overrides: [String: String]) {
        self.base = base
        self.overrides = overrides
    }

    public func secret(forName name: String) throws -> String? {
        if let value = overrides[name] { return value }
        return try base.secret(forName: name)
    }

    public func setSecret(_ value: String, forName name: String) throws {
        try base.setSecret(value, forName: name)
    }

    public func deleteSecret(forName name: String) throws {
        try base.deleteSecret(forName: name)
    }

    public func listSecretNames() throws -> [String] {
        try base.listSecretNames()
    }
}
