import Foundation

/// `{{degisken}}` ve `{{secret:isim}}` şablonlarını çözer.
///
/// Çözüm sırası:
/// 1. `{{secret:isim}}` → SecretStore (Keychain)
/// 2. `{{isim}}` → aktif environment değişkenleri (değer yine şablon içerebilir,
///    tek seviye daha çözülür; sonsuz döngüye izin verilmez)
///
/// Bulunamayan referanslar hata üretir — sessizce boş string'e düşmek,
/// yanlış hedefe istek atılmasına yol açabileceği için tercih edilmedi.
public struct VariableResolver: Sendable {
    public enum ResolveError: Error, LocalizedError, Equatable {
        case unknownVariable(String)
        case unknownSecret(String)
        case nestingTooDeep(String)
        case variableIsSecret(String)

        public var errorDescription: String? {
            switch self {
            case .unknownVariable(let name):
                return L10n.t("resolver.undefined", name)
            case .variableIsSecret(let name):
                return L10n.t("resolver.isSecret", name)
            case .unknownSecret(let name):
                return L10n.t("resolver.undefinedSecret", name)
            case .nestingTooDeep(let name):
                return L10n.t("resolver.tooDeep", name)
            }
        }
    }

    private let variables: [String: String]
    private let secretStore: SecretStore
    private static let maxDepth = 5

    public init(environment: EnvironmentModel?, secretStore: SecretStore) {
        var vars: [String: String] = [:]
        for entry in environment?.variables ?? [] where entry.enabled && !entry.key.isEmpty {
            vars[entry.key] = entry.value
        }
        self.variables = vars
        self.secretStore = secretStore
    }

    /// Vault'tan doğrudan okuma (OAuth2 token'ı gibi şablon olmayan değerler için).
    public func secret(named name: String) throws -> String? {
        try secretStore.secret(forName: name)
    }

    /// Metindeki tüm şablonları çözer. Şablon içermeyen metin olduğu gibi döner.
    public func resolve(_ text: String) throws -> String {
        var usesSecret = false
        return try resolve(text, depth: 0, usesSecret: &usesSecret)
    }

    /// Çözer ve sonuçta bir secret'ın değeri olup olmadığını söyler. Tüm
    /// yollar aynı ayrıştırıcıdan geçer: doğrudan `{{secret:x}}`, boşluklu
    /// `{{ secret:x }}` ve secret'a çıkan environment değişkeni zinciri.
    /// Yönlendirmede hangi başlığın düşürüleceği buna göre belirlenir.
    public func resolveTrackingSecrets(_ text: String) throws -> (value: String, usesSecret: Bool) {
        var usesSecret = false
        let value = try resolve(text, depth: 0, usesSecret: &usesSecret)
        return (value, usesSecret)
    }

    private func resolve(_ text: String, depth: Int, usesSecret: inout Bool) throws -> String {
        guard text.contains("{{") else { return text }
        guard depth < Self.maxDepth else { throw ResolveError.nestingTooDeep(text) }

        var output = ""
        var lastIndex = text.startIndex
        for match in TemplateScanner.matches(in: text) {
            output += text[lastIndex..<match.range.lowerBound]
            let token = String(match.name)
            if token.hasPrefix("secret:") {
                let name = String(token.dropFirst("secret:".count)).trimmingCharacters(in: .whitespaces)
                guard let value = try secretStore.secret(forName: name) else {
                    throw ResolveError.unknownSecret(name)
                }
                usesSecret = true
                output += value
            } else {
                guard let value = variables[token] else {
                    // Aynı isimde secret varsa kullanıcı büyük olasılıkla
                    // {{secret:...}} önekini unutmuştur; doğru yazımı öner.
                    if (try? secretStore.secret(forName: token)) != nil {
                        throw ResolveError.variableIsSecret(token)
                    }
                    throw ResolveError.unknownVariable(token)
                }
                output += try resolve(value, depth: depth + 1, usesSecret: &usesSecret)
            }
            lastIndex = match.range.upperBound
        }
        output += text[lastIndex...]
        return output
    }
}
