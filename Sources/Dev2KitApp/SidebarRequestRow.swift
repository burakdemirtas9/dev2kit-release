import SwiftUI
import Dev2KitCore

/// Kenar çubuğundaki istek satırı ve sağ tık menüsü.
///
/// Sağ tıklanan satır seçimin içindeyse işlem TÜM seçime, dışındaysa yalnızca
/// o satıra uygulanır (`MultiSelection.targets`). Silme onay ister; onay
/// kutusu listenin sahibinde (`SidebarView`), burası yalnızca hedefi bildirir.
struct SidebarRequestRow: View {
    @Environment(AppState.self) private var appState
    let request: RequestModel
    let collection: CollectionModel
    let isDirty: Bool
    let onDelete: (Set<UUID>) -> Void

    var body: some View {
        HStack {
            Text(request.method.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.color(for: request.method))
                .frame(width: 44, alignment: .leading)
            Text(request.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isDirty {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Theme.warning)
                    .help(L10n.t("request.dirty.short"))
            }
        }
        // Tek tıklama önizler (liste seçimi). Çift tıklama sekmeyi
        // kalıcı yapar; o iş satır içeriğinde DEĞİL, AppKit olay
        // akışında (bkz. SidebarDoubleClick) — gesture buraya
        // bağlanınca tek tıklamayı yutuyor.
        .contextMenu {
            // Sağ tıklanan satır seçimin içindeyse işlem TÜM
            // seçime, dışındaysa yalnızca o satıra uygulanır.
            let picked = MultiSelection.targets(
                forContextMenuOn: request.id,
                selection: appState.selectedRequestIDs
            )
            let isMultiple = picked.count > 1
            if !isMultiple {
                Button {
                    appState.duplicateRequest(request.id)
                } label: {
                    Label(L10n.t("request.duplicate"), systemImage: "plus.square.on.square")
                }
            }
            let targets = appState.workspace.regularCollections.filter { $0.id != collection.id }
            if !targets.isEmpty {
                Menu {
                    ForEach(targets) { target in
                        Button(target.name) {
                            appState.moveRequests(picked, toCollection: target.id)
                        }
                    }
                } label: {
                    Label(isMultiple ? L10n.plural("request.moveMany", count: picked.count) : L10n.t("request.move"),
                          systemImage: "folder")
                }
            }
            Button {
                appState.copyToTokenFactory(picked)
            } label: {
                Label(isMultiple ? L10n.plural("request.copyToTokenMany", count: picked.count) : L10n.t("request.copyToToken"),
                      systemImage: "key.viewfinder")
            }
            if !collection.isUngrouped {
                Button {
                    appState.removeFromCollection(picked)
                } label: {
                    Label(isMultiple ? L10n.plural("request.removeFromCollectionMany", count: picked.count) : L10n.t("request.removeFromCollection"),
                          systemImage: "tray")
                }
            }
            Divider()
            Button(role: .destructive) {
                onDelete(picked)
            } label: {
                Label(isMultiple ? L10n.plural("request.deleteManyEllipsis", count: picked.count) : L10n.t("common.deleteEllipsis"), systemImage: "trash")
            }
        }
    }
}
