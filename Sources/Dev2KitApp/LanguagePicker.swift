import SwiftUI
import Dev2KitCore

/// Araç çubuğundaki dil seçici (her iki modda): "Türkçe / English".
/// Görünüm seçicisiyle aynı kalıp; seçim anında uygulanır ve saklanır.
struct LanguagePicker: View {
    var body: some View {
        Picker(selection: Binding(
            get: { Localizer.shared.language },
            set: { Localizer.shared.language = $0 }
        )) {
            // Araç çubuğundaki menü Picker'ı SEÇİLİ öğenin içeriğini gösterir
            // (kendi etiketini değil); öğeler düz Text olunca 36 pt'lik
            // düğme boş görünüyordu. Görünüm seçicisindeki gibi simgeli Label.
            ForEach(AppLanguage.allCases) { language in
                Label(language.displayName, systemImage: "character.bubble").tag(language)
            }
        } label: {
            Label(L10n.t("common.language"), systemImage: "character.bubble")
        }
        .pickerStyle(.menu)
        .menuIndicator(.hidden)
        .frame(width: 36)
        .help(L10n.t("common.language.help"))
        .accessibilityLabel(L10n.t("common.language"))
        .accessibilityValue(Localizer.shared.language.displayName)
    }
}
