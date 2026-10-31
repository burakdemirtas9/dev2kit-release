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

/// Öneri listesinde klavyeyle gezinme (kullanıcı isteği, 2026-11-01):
/// ↑/↓ vurguyu taşır (uçlarda başa sarar), ⏎/⇥ vurgulananı seçer, Esc o
/// yazım için listeyi kapatır.
///
/// Kurallar: ilk öneri baştan vurgulu (VS Code gibi, ⏎ hemen tamamlar);
/// liste değişince (yazdıkça) vurgu başa döner; Esc ile kapatılan liste aynı
/// `{{…` için kapalı kalır, yazmaya devam edince yeniden açılır.
public struct SuggestionNavigator: Equatable, Sendable {
    public private(set) var items: [String] = []
    public private(set) var index = 0
    /// Esc'e basıldığındaki yazım (`{{`'den sonrası); aynıyken liste kapalı.
    private var dismissedToken: String?

    public init() {}

    /// Görünen liste: yazım kapatılmışsa boş.
    public func visible(for token: String?) -> [String] {
        guard let token, token != dismissedToken else { return [] }
        return items
    }

    public var selected: String? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// Yeni öneriler (yazdıkça). Liste aynıysa vurgu korunur.
    public mutating func update(_ newItems: [String], token: String?) {
        if token != dismissedToken { dismissedToken = nil }
        guard newItems != items else { return }
        items = newItems
        index = 0
    }

    public mutating func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = ((index + delta) % items.count + items.count) % items.count
    }

    /// Fareyle üzerine gelinen satır.
    public mutating func highlight(_ newIndex: Int) {
        if items.indices.contains(newIndex) { index = newIndex }
    }

    public mutating func dismiss(token: String?) {
        dismissedToken = token
    }
}
