import SwiftUI
import Dev2KitCore

struct EnvironmentPicker: View {
    @Environment(AppState.self) private var appState

    /// Toolbar'da görünen ad: seçili environment, uzunsa kırpılmış hali.
    private var selectedLabel: String {
        guard let environment = appState.activeEnvironment else { return L10n.t("environment.none") }
        let name = DisplayName.truncated(environment.name, limit: DisplayName.environmentPickerLimit)
        return name.isEmpty ? L10n.t("common.unnamed.title") : name
    }

    /// Kırpılmış adın tamamı fare üstüne gelince görünür.
    private var helpText: String {
        guard let environment = appState.activeEnvironment else { return L10n.t("environment.active") }
        let full = environment.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? L10n.t("environment.active") : L10n.t("environment.active.named", full)
    }

    var body: some View {
        @Bindable var state = appState
        // Picker doğrudan toolbar'a konunca genişliğini EN UZUN seçeneğe göre
        // alıyordu: tek bir uzun ad seçili olmasa bile seçiciyi genişletip
        // toolbar'ı itiyordu. Menu + inline Picker ile genişliği yalnızca
        // seçili ad belirler; açılır listede adlar tam haliyle görünür.
        //
        // Toolbar içerideki etiketlere "yalnızca ikon" stili uyguluyor; seçili
        // değer düz metin olduğu için boş görünüyordu. titleOnly bunu yalnızca
        // burada geri alır, diğer toolbar düğmeleri ikon kalır.
        Menu {
            Picker("Environment", selection: $state.workspace.activeEnvironmentID) {
                Text(L10n.t("environment.none")).tag(UUID?.none)
                ForEach(appState.workspace.environments) { environment in
                    Text(environment.name).tag(UUID?.some(environment.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(selectedLabel)
        }
        .fixedSize()
        .labelStyle(.titleOnly)
        .help(helpText)
        .onChange(of: appState.workspace.activeEnvironmentID) {
            appState.persist()
        }
    }
}
