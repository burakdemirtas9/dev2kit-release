import SwiftUI
import Dev2KitCore

/// Kenar çubuğundaki koleksiyon başlığı: daralt/genişlet, sürükleyerek
/// sıralama, üzerine bırakılan istekleri taşıma, sağ tık menüsü.
///
/// Daralt/genişlet hedefi başlığın TAMAMI ve bir `Button`: List section
/// header'ında düz `.onTapGesture` tıklama almıyor (NSTableView olayı
/// yutuyor), Button alıyor — bkz. docs/UI-KURALLARI.md.
struct SidebarCollectionHeader: View {
    @Environment(AppState.self) private var appState
    /// Kenar çubuğu özeti (`SidebarSnapshot`): arama açıkken `requests`
    /// yalnızca eşleşenler, `totalRequests` koleksiyonun tamamı.
    let collection: SidebarSnapshot.Collection
    /// Gösterimdeki hal: aramada daraltılmış koleksiyonlar da açık görünür.
    let isCollapsed: Bool
    /// Daraltılmışken içinde "son gönderilenden farklı" istek var mı.
    /// Çağıran yalnızca daraltılmışsa hesaplar (satır başına tarama yok).
    let containsDirtyRequest: Bool
    /// Başka bir koleksiyon sürüklenirken soluklaşır.
    let isDimmed: Bool
    @Binding var draggingCollectionID: UUID?
    let onRename: () -> Void
    /// Kurum collection'larından sonraki ilk kendi collection'ı: üstünde
    /// "Collection'larım" başlığı durur.
    var isFirstOwn: Bool = false
    /// Bu collection'a istek eklenebilir mi (aramada ve salt okunur kurum
    /// collection'ında hayır). Artı düğmesi ve menü satırı buna bakar.
    var canAddRequest: Bool = false
    let onDelete: () -> Void
    @State private var isHovered = false
    /// Üzerinde kabul edilebilecek istekler sürükleniyor.
    @State private var isRequestDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isFirstOwn {
                Text(L10n.t("team.mine").uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            header
        }
    }

    private var header: some View {
        // Daralt/genişlet hedefi başlığın TAMAMI. Bunun Button olması
        // ŞART: List section header'ında düz .onTapGesture tıklama
        // almıyor (NSTableView olayı yutuyor), Button alıyor.
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                appState.toggleCollectionCollapsed(collection.id)
            }
            // Kurum collection'ının içeriği ilk açılışta çekilir.
            if collection.team?.isLoaded == false, !appState.isCollectionCollapsed(collection.id) {
                Task { await appState.teamLoad(collection.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.tinyText.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                if collection.isUngrouped {
                    // Sürüklenemez, yeniden adlandırılamaz: tutamaç yerine kendi simgesi.
                    Image(systemName: "tray")
                        .font(.tinyText)
                        .foregroundStyle(.secondary)
                    Text(collection.displayName)
                        .foregroundStyle(.secondary)
                } else if let team = collection.team {
                    // Kurum collection'ı: sürüklenmez; kilit = salt okunur, kalem = düzenlenebilir.
                    Image(systemName: team.canEdit ? "pencil" : "lock")
                        .font(.tinyText)
                        .foregroundStyle(Theme.purple)
                    Text(collection.displayName)
                    Text(team.ownerGroup)
                        .font(.tinyMono)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Image(systemName: "line.3.horizontal")
                        .font(.tinyText)
                        .foregroundStyle(.quaternary)
                    Text(collection.displayName)
                }
                // Aramada "eşleşen/toplam", normalde yalnızca toplam.
                Text(appState.isSearching && collection.requests.count != collection.totalRequests
                     ? "\(collection.requests.count)/\(collection.totalRequests)"
                     : "\(collection.totalRequests)")
                    .font(.tinyText)
                    .foregroundStyle(.tertiary)
                if collection.team?.isDirty == true {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Theme.accent)
                        .help(L10n.t("team.banner.dirty"))
                }
                if isCollapsed, containsDirtyRequest {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Theme.warning)
                        .help(L10n.t("collection.hasDirty"))
                }
                Spacer(minLength: 0)
            }
            // Önceden yalnızca 14pt'lik chevron tıklanabiliyordu;
            // koleksiyon adına basmak hiçbir şey yapmadığı için
            // nişan almak gerekiyordu.
            .frame(minHeight: HitTarget.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isRequestDropTarget {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.accent.opacity(0.12))
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .padding(.horizontal, -4)
            }
        }
        // Aramada gösterim zorla açık olduğu için daraltma yanıltıcı
        // olurdu: basınca hiçbir şey değişmiyormuş gibi görünür.
        .disabled(appState.isSearching)
        .help(appState.isSearching
              ? L10n.t("collection.searchExpanded")
              : (appState.isCollectionCollapsed(collection.id) ? L10n.t("collection.expand") : L10n.t("collection.collapse")))
        // Yeni istek: her collection'ın altındaki satırın yerine başlıkta artı.
        // Üzerine gelince görünür; boş collection'da hep görünür (başka ipucu
        // yok). Klavye yolu: ⌘N ve sağ tık menüsü.
        .overlay(alignment: .trailing) {
            if canAddRequest, isHovered || collection.totalRequests == 0 {
                Button {
                    appState.addRequest(to: collection.id)
                } label: {
                    Image(systemName: "plus").iconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.t("collection.addRequest.help"))
                .accessibilityLabel(L10n.t("menu.newRequest"))
                .disabled(draggingCollectionID != nil)
            }
        }
        .onHover { isHovered = $0 }
        .opacity(isDimmed ? 0.35 : 1)
        .onDrag {
            // Filtreliyken sıralama kapalı: görünen liste gerçek
            // sırayı temsil etmiyor. Boş sağlayıcı dönünce
            // `draggingCollectionID` set edilmez ve drop hedefleri
            // (bkz. CollectionReorderDelegate) hiçbir şey yapmaz.
            guard !appState.isSearching, !collection.isUngrouped, collection.team == nil else { return NSItemProvider() }
            draggingCollectionID = collection.id
            return InternalDrag.provider(for: collection.id)
        }
        .onDrop(
            of: [InternalDrag.type],
            delegate: CollectionReorderDelegate(
                target: collection.id,
                acceptsRequests: collection.acceptsRequestDrop,
                dragging: $draggingCollectionID,
                isRequestTarget: $isRequestDropTarget,
                appState: appState
            )
        )
        .contextMenu {
            if let team = collection.team {
                teamMenu(team)
            } else if !collection.isUngrouped {
                if canAddRequest { newRequestMenuItem; Divider() }
                Button {
                    onRename()
                } label: {
                    Label(L10n.t("collection.renameEllipsis"), systemImage: "pencil")
                }
                Divider()
                Button {
                    appState.exportCollection(collection.id)
                } label: {
                    Label(L10n.t("collection.export"), systemImage: "square.and.arrow.up")
                }
                Button {
                    appState.exportCollection(collection.id, format: .postman)
                } label: {
                    Label(L10n.t("collection.exportPostman"), systemImage: "square.and.arrow.up.on.square")
                }
                if appState.teamIdentity != nil, appState.teamCanCreate {
                    Button {
                        Task { await appState.teamPublish(collection.id) }
                    } label: {
                        Label(L10n.t("team.publish"), systemImage: "building.2")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(L10n.t("common.deleteEllipsis"), systemImage: "trash")
                }
            }
        }
    }

    private var newRequestMenuItem: some View {
        Button {
            appState.addRequest(to: collection.id)
        } label: {
            Label(L10n.t("menu.newRequest"), systemImage: "plus")
        }
    }

    @ViewBuilder
    private func teamMenu(_ team: SidebarSnapshot.Team) -> some View {
        if canAddRequest { newRequestMenuItem }
        if team.canEdit {
            // Ad yerelde değişir; "Sunucuya kaydet" ile gider.
            Button {
                onRename()
            } label: {
                Label(L10n.t("collection.renameEllipsis"), systemImage: "pencil")
            }
            Divider()
        }
        if team.isDirty {
            Button {
                Task { await appState.teamSave(collection.id) }
            } label: {
                Label(L10n.t("team.save"), systemImage: "icloud.and.arrow.up")
            }
        }
        Button {
            Task { await appState.teamRefresh(reloadLoaded: true) }
        } label: {
            Label(L10n.t("team.refresh"), systemImage: "arrow.clockwise")
        }
        Button {
            appState.teamCopyToMine(collection.id)
        } label: {
            Label(L10n.t("team.copyToMine"), systemImage: "doc.on.doc")
        }
        .disabled(!team.isLoaded)
        if appState.teamCatalog.canDelete(collection.id) {
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(L10n.t("common.deleteEllipsis"), systemImage: "trash")
            }
        }
    }
}

/// Koleksiyon başlıkları arasında canlı sıralama: sürüklenen başlık başka bir
/// başlığın üzerine gelince yer değiştirir, bırakınca konum sabitlenir.
/// Drop hedefi yalnızca başlıklar olduğu için bir koleksiyon başka bir
/// koleksiyonun İÇİNE bırakılamaz.
/// Başlığa bırakma: sürüklenen bir collection'sa sıralama (hover sırasında
/// canlı), istek(ler)se bu collection'a taşıma ya da kurum collection'ına
/// kopyalama (`AppState.dropRequests`, 2026-11-16). İstek sürüklemesi
/// `dragging`'i set etmez; ayrım buradan yapılır. Kabul etmeyen başlık
/// (salt okunur kurum collection'ı, Token Factory) yasak imleci gösterir.
struct CollectionReorderDelegate: DropDelegate {
    let target: UUID
    let acceptsRequests: Bool
    @Binding var dragging: UUID?
    @Binding var isRequestTarget: Bool
    let appState: AppState

    private var isDraggingRequests: Bool { dragging == nil }

    func dropEntered(info: DropInfo) {
        if isDraggingRequests {
            isRequestTarget = acceptsRequests
            return
        }
        // Kurum collection'ları sunucu sırasıyla en üstte; araya girilmez.
        guard let dragging, dragging != target, !appState.isTeamCollection(target) else { return }
        appState.moveCollection(dragging, before: target)
    }

    func dropExited(info: DropInfo) {
        isRequestTarget = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isDraggingRequests && !acceptsRequests ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let wasReordering = !isDraggingRequests
        dragging = nil
        isRequestTarget = false
        guard !wasReordering else { return true }
        // Kimlikler sürükleme başlarken yazıldı (`draggedRequestIDs`): yükten
        // okumak liste satırında boş dönüyor ve bekletiyordu.
        let ids = appState.draggedRequestIDs
        appState.draggedRequestIDs = []
        guard acceptsRequests, !ids.isEmpty else { return false }
        appState.dropRequests(ids, on: target)
        return true
    }
}
