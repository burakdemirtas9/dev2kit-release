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
                return "Tanımsız değişken: {{\(name)}} — aktif environment'ı kontrol et."
            case .variableIsSecret(let name):
                return "\"\(name)\" bir secret — {{secret:\(name)}} olarak yazmalısın."
            case .unknownSecret(let name):
                return "Tanımsız secret: {{secret:\(name)}} — Secrets ekranından ekleyebilirsin."
            case .nestingTooDeep(let name):
                return "Değişken çözümü çok derin: {{\(name)}} (döngüsel referans olabilir)."
            }
        }
    }

    private let variables: [String: String]
    private let secretStore: SecretStore
    private static let pattern = #/\{\{\s*([^{}]+?)\s*\}\}/#
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
        try resolve(text, depth: 0)
    }

    private func resolve(_ text: String, depth: Int) throws -> String {
        guard text.contains("{{") else { return text }
        guard depth < Self.maxDepth else { throw ResolveError.nestingTooDeep(text) }

        var output = ""
        var lastIndex = text.startIndex
        for match in text.matches(of: Self.pattern) {
            output += text[lastIndex..<match.range.lowerBound]
            let token = String(match.1)
            if token.hasPrefix("secret:") {
                let name = String(token.dropFirst("secret:".count)).trimmingCharacters(in: .whitespaces)
                guard let value = try secretStore.secret(forName: name) else {
                    throw ResolveError.unknownSecret(name)
                }
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
                output += try resolve(value, depth: depth + 1)
            }
            lastIndex = match.range.upperBound
        }
        output += text[lastIndex...]
        return output
    }
}
