import SwiftUI
import Dev2KitCore

/// Kenar çubuğundaki istek satırı ve sağ tık menüsü.
///
/// Örneği olan isteğin solunda örnekleri açıp katlayan ok durur; örneği
/// olmayanlarda aynı genişlikte boşluk kalır, metot sütunu hizalı kalsın.
/// Ok bir `Button`: satır içeriğine tıklama gesture'ı bağlanmaz (UI-KURALLARI §2c).
///
/// Sağ tıklanan satır seçimin içindeyse işlem TÜM seçime, dışındaysa yalnızca
/// o satıra uygulanır (`MultiSelection.targets`). Silme onay ister; onay
/// kutusu listenin sahibinde (`SidebarView`), burası yalnızca hedefi bildirir.
struct SidebarRequestRow: View {
    @Environment(AppState.self) private var appState
    let request: RequestModel
    let collection: CollectionModel
    let isDirty: Bool
    let examplesExpanded: Bool
    let onDelete: (Set<UUID>) -> Void

    /// Okun sütunu; örnek satırlarının girintisi buna göre (`SidebarExampleRow`).
    static let toggleWidth: CGFloat = 22
    /// Okun yerleşimdeki yüksekliği: yazı satırı kadar. 22 pt'lik kare satırı
    /// 24'ten 30 pt'ye çıkarıyordu, kenar çubuğu seyrekleşiyordu (ölçüldü,
    /// `ExampleFoldingTests`).
    static let toggleHeight: CGFloat = 16

    var body: some View {
        HStack(spacing: 0) {
            examplesToggle
            HStack {
                Text(request.method.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.color(for: request.method))
                    .frame(width: 44, alignment: .leading)
                Text(request.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !request.examples.isEmpty {
                    Text("\(request.examples.count)")
                        .font(.tinyText)
                        .foregroundStyle(.tertiary)
                        .help(L10n.plural("example.count", count: request.examples.count))
                }
                statusMarks
            }
        }
        // Tek tıklama önizler (liste seçimi). Çift tıklama sekmeyi
        // kalıcı yapar; o iş satır içeriğinde DEĞİL, AppKit olay
        // akışında (bkz. SidebarDoubleClick) — gesture buraya
        // bağlanınca tek tıklamayı yutuyor.
        .contextMenu { menu }
    }

    /// Örnekleri aç/katla. Örnek yoksa yalnızca hizalama boşluğu.
    @ViewBuilder private var examplesToggle: some View {
        if request.examples.isEmpty {
            // Okla aynı ölçü: örneği olan ve olmayan satırlar aynı yükseklikte.
            Color.clear.frame(width: Self.toggleWidth, height: Self.toggleHeight)
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.toggleExamples(request.id)
                }
            } label: {
                Image(systemName: examplesExpanded ? "chevron.down" : "chevron.right")
                    .font(.tinyText.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.toggleWidth, height: Self.toggleHeight)
                    // Tıklama alanı satırın tam yüksekliği (24 pt): dikey
                    // dolgu yalnızca şekle eklenir, yerleşimden geri alınır.
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .padding(.vertical, -4)
            }
            .buttonStyle(.plain)
            .help(examplesExpanded ? L10n.t("example.fold.hide") : L10n.t("example.fold.show"))
            .accessibilityLabel(examplesExpanded ? L10n.t("example.fold.hide") : L10n.t("example.fold.show"))
        }
    }

    @ViewBuilder private var statusMarks: some View {
        if isDirty {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(Theme.warning)
                .help(L10n.t("request.dirty.short"))
        }
    }

    @ViewBuilder private var menu: some View {
        // Sağ tıklanan satır seçimin içindeyse işlem TÜM
        // seçime, dışındaysa yalnızca o satıra uygulanır.
        let picked = MultiSelection.targets(
            forContextMenuOn: request.id,
            selection: appState.selectedRequestIDs
        )
        let isMultiple = picked.count > 1
        // Klavye ve VoiceOver için okun karşılığı.
        if !isMultiple, !request.examples.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.toggleExamples(request.id)
                }
            } label: {
                Label(examplesExpanded ? L10n.t("example.fold.hide") : L10n.t("example.fold.show"),
                      systemImage: examplesExpanded ? "chevron.down" : "chevron.right")
            }
            Divider()
        }
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
