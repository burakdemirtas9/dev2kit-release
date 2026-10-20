import SwiftUI
import Dev2KitCore

/// Araç çubuğundaki environment seçici.
///
/// Menü değil popover: her environment satırının sağında, o environment'ın
/// değerlerini doğrudan açan bir düğme var (kullanıcı isteği, 2026-10-20);
/// sistem menüsü satır içinde düğme taşıyamıyor. Böylece ayrı bir
/// "Environment'lar" düğmesine gerek kalmadı. Environment yoksa en altta
/// "Environment Ekle".
struct EnvironmentPicker: View {
    @Environment(AppState.self) private var appState
    @State private var isOpen = false

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
        // Genişliği yalnızca seçili ad belirler (uzun bir seçenek seçiciyi
        // genişletip araç çubuğunu itmesin); listede adlar tam görünür.
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(selectedLabel).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            // Kapsülün tamamı tıklanır (cam çağıranın; boşluk düğmenin içinde).
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel(L10n.t("environment.active"))
        .accessibilityValue(selectedLabel)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            EnvironmentPickerList(close: { isOpen = false })
        }
        .onChange(of: appState.workspace.activeEnvironmentID) {
            appState.persist()
        }
    }
}

/// Popover içeriği: başlık, "Environment Yok", environment'lar (sağda
/// düzenle düğmesi), environment yoksa en altta "Environment Ekle".
struct EnvironmentPickerList: View {
    @Environment(AppState.self) private var appState
    let close: () -> Void

    var body: some View {
        let environments = appState.workspace.environments
        let activeID = appState.workspace.activeEnvironmentID
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("environment.header"))
                .font(.secondaryText.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 4)

            EnvironmentPickerRow(title: L10n.t("environment.none"), isSelected: activeID == nil) {
                select(nil)
            }
            ForEach(environments) { environment in
                let name = environment.name.trimmingCharacters(in: .whitespacesAndNewlines)
                EnvironmentPickerRow(
                    title: name.isEmpty ? L10n.t("common.unnamed.title") : environment.name,
                    isSelected: activeID == environment.id,
                    onEdit: { edit(environment.id) }
                ) {
                    select(environment.id)
                }
            }
            if environments.isEmpty {
                Divider().padding(.vertical, 4)
                Button {
                    close()
                    let id = appState.addEnvironment()
                    // Yeni environment adlandırılsın ve değerleri girilsin.
                    appState.showEnvironments(focus: id)
                } label: {
                    Label(L10n.t("environment.add"), systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .rowHitTarget()
                }
                .buttonStyle(PickerRowButtonStyle())
            }
        }
        .padding(6)
        .frame(minWidth: 220, maxWidth: 320)
    }

    private func select(_ id: UUID?) {
        appState.workspace.activeEnvironmentID = id
        close()
    }

    private func edit(_ id: UUID) {
        close()
        appState.showEnvironments(focus: id)
    }
}

/// Seçim satırı: solda onay işareti, ad; isteğe bağlı sağda düzenle düğmesi.
private struct EnvironmentPickerRow: View {
    let title: String
    let isSelected: Bool
    var onEdit: (() -> Void)?
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Satır gövdesi kendi düğmesi; düzenle düğmesi onun DIŞINDA
            // (iç içe düğmede tıklama gövdeye gidiyordu).
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 14)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 6)
                .rowHitTarget()
            }
            .buttonStyle(PickerRowButtonStyle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13))
                        .iconHitTarget()
                }
                .buttonStyle(PickerRowButtonStyle())
                .help(L10n.t("environment.edit", title))
                .accessibilityLabel(L10n.t("environment.edit", title))
            }
        }
    }
}

/// Menü satırı gibi: fareyle üstüne gelince vurgulanır.
private struct PickerRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.3 : isHovered ? 0.18 : 0))
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
