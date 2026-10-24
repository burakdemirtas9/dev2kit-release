import SwiftUI
import Dev2KitCore

/// Kenar çubuğunda isteğin altındaki kayıtlı örnek. Seçimi liste yapar
/// (etiket örnek kimliği, bkz. `SidebarView.listSelection`); satıra gesture
/// bağlanmaz. "(e.g.)" göstergesi dil ne olursa olsun aynı.
struct SidebarExampleRow: View {
    @Environment(AppState.self) private var appState
    let ref: AppState.ExampleRef
    let example: ResponseExample

    var body: some View {
        HStack(spacing: 6) {
            Text(ResponseExamples.badge)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(example.name)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(ResponseExamples.statusLabel(example.statusCode))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.statusColor(example.statusCode))
        }
        // İstek satırındaki metot sütununun hizasından başlar: altında
        // olduğu görülsün.
        .padding(.leading, 24)
        .help(example.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("example.accessibility", example.name, ResponseExamples.statusLabel(example.statusCode)))
        .contextMenu {
            Button {
                appState.exampleRenameTarget = ref
            } label: {
                Label(L10n.t("example.rename"), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                appState.exampleDeleteTarget = ref
            } label: {
                Label(L10n.t("common.deleteEllipsis"), systemImage: "trash")
            }
        }
    }
}
