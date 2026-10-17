import Foundation

/// `{{...}}` yazarken çıkan öneri listesi.
///
/// Sıra bilinçli: önce environment değişkenleri, sonra Token Factory değişkenleri,
/// en son `secret:` girdileri — kullanıcı en sık ilkini arıyor.
public enum TemplateSuggestions {
    public static let limit = 8

    public static func options(
        environment: EnvironmentModel?,
        secretNames: [String],
        tokenVariables: [String] = [],
        matching token: String,
        limit: Int = limit
    ) -> [String] {
        var options = environment?.variables
            .filter { $0.enabled && !$0.key.isEmpty }
            .map(\.key) ?? []
        // Token Factory değişkeni environment değişkeniyle çakışabilir; tekrar etmesin.
        options += tokenVariables.filter { !$0.isEmpty && !options.contains($0) }
        options += secretNames.map { "secret:\($0)" }

        let query = token.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? options : options.filter { $0.lowercased().contains(query) }
        return Array(filtered.prefix(limit))
    }
}
