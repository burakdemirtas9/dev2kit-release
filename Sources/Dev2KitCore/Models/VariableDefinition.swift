import Foundation

/// Tanımsız `{{değişken}}`e tıklanınca değerini vermek: hangi environment'a,
/// mevcut satıra mı yeni satıra mı (kullanıcı isteği, 2026-10-20).
///
/// Çözüm `TemplateVariables.preview` ile aynı kuralda: etkin environment'taki
/// SON açık satır kazanır. Kayıt yalnızca kullanıcı kaydedince yapılır; burada
/// karar ve kaydın kendisi var, görünüm yok.
public enum VariableDefinition {
    /// Alandaki şablondan anahtar: `{{` `}}` ve boşluk atılır. `secret:` ve
    /// boş adlar environment'a yazılmaz (`nil`).
    public static func key(from raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("{{") { text.removeFirst(2) }
        if text.hasSuffix("}}") { text.removeLast(2) }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("secret:"), !text.contains("{"), !text.contains("}") else { return nil }
        return text
    }

    /// Değerin yazılacağı environment.
    public enum Target: Equatable, Sendable {
        /// İsteğin kullandığı (etkin) environment ya da tek environment.
        case environment(UUID)
        /// Etkin environment yok ve birden fazla var: kullanıcı seçer.
        case choose
        /// Hiç environment yok: kaydedince yenisi oluşturulur.
        case createNew
    }

    public static func target(activeID: UUID?, environments: [EnvironmentModel]) -> Target {
        if let activeID, environments.contains(where: { $0.id == activeID }) {
            return .environment(activeID)
        }
        switch environments.count {
        case 0: return .createNew
        case 1: return .environment(environments[0].id)
        default: return .choose
        }
    }

    /// Environment'ta bu anahtar zaten var mı.
    public enum Plan: Equatable, Sendable {
        /// Satır var: ona gidilir. Kapalıysa (`isDisabled`) değer verilse de
        /// açılana kadar kullanılmaz; kullanıcıya söylenir.
        case existing(entryID: UUID, isDisabled: Bool)
        case new
    }

    public static func plan(for key: String, in environment: EnvironmentModel) -> Plan {
        // Çözümle aynı satır: son açık olan; yoksa son kapalı olan.
        if let entry = environment.variables.last(where: { $0.enabled && $0.key == key }) {
            return .existing(entryID: entry.id, isDisabled: false)
        }
        if let entry = environment.variables.last(where: { $0.key == key }) {
            return .existing(entryID: entry.id, isDisabled: true)
        }
        return .new
    }

    public enum SaveError: Error, Equatable {
        case emptyKey
        /// Taslak beklerken aynı adla satır eklenmiş: mevcut değerin üzerine
        /// sessizce yazılmaz.
        case duplicate
    }

    /// Yeni değişkeni ekler (açık satır, environment'ın sonuna). Mevcut
    /// değerlere dokunmaz.
    public static func add(key rawKey: String, value: String, to environment: inout EnvironmentModel) throws {
        let key = rawKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw SaveError.emptyKey }
        guard !environment.variables.contains(where: { $0.key == key }) else { throw SaveError.duplicate }
        environment.variables.append(KeyValueEntry(key: key, value: value, enabled: true))
    }
}
