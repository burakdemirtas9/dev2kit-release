import SwiftUI
import Dev2KitCore

/// Kenar çubuğundaki koleksiyon başlığı: daralt/genişlet, sürükleyerek
/// sıralama, sağ tık menüsü.
///
/// Daralt/genişlet hedefi başlığın TAMAMI ve bir `Button`: List section
/// header'ında düz `.onTapGesture` tıklama almıyor (NSTableView olayı
/// yutuyor), Button alıyor — bkz. docs/UI-KURALLARI.md.
struct SidebarCollectionHeader: View {
    @Environment(AppState.self) private var appState
    let match: RequestSearch.Match
    /// Gösterimdeki hal: aramada daraltılmış koleksiyonlar da açık görünür.
    let isCollapsed: Bool
    /// Daraltılmışken içinde "son gönderilenden farklı" istek var mı.
    /// Çağıran yalnızca daraltılmışsa hesaplar (satır başına tarama yok).
    let containsDirtyRequest: Bool
    /// Başka bir koleksiyon sürüklenirken soluklaşır.
    let isDimmed: Bool
    @Binding var draggingCollectionID: UUID?
    let onRename: () -> Void
    let onDelete: () -> Void

    private var collection: CollectionModel { match.collection }

    var body: some View {
        // Daralt/genişlet hedefi başlığın TAMAMI. Bunun Button olması
        // ŞART: List section header'ında düz .onTapGesture tıklama
        // almıyor (NSTableView olayı yutuyor), Button alıyor.
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                appState.toggleCollectionCollapsed(collection.id)
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
                } else {
                    Image(systemName: "line.3.horizontal")
                        .font(.tinyText)
                        .foregroundStyle(.quaternary)
                    Text(collection.displayName)
                }
                // Aramada "eşleşen/toplam", normalde yalnızca toplam.
                Text(appState.isSearching && match.requests.count != collection.requests.count
                     ? "\(match.requests.count)/\(collection.requests.count)"
                     : "\(collection.requests.count)")
                    .font(.tinyText)
                    .foregroundStyle(.tertiary)
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
        // Aramada gösterim zorla açık olduğu için daraltma yanıltıcı
        // olurdu: basınca hiçbir şey değişmiyormuş gibi görünür.
        .disabled(appState.isSearching)
        .help(appState.isSearching
              ? L10n.t("collection.searchExpanded")
              : (appState.isCollectionCollapsed(collection.id) ? L10n.t("collection.expand") : L10n.t("collection.collapse")))
        .opacity(isDimmed ? 0.35 : 1)
        .onDrag {
            // Filtreliyken sıralama kapalı: görünen liste gerçek
            // sırayı temsil etmiyor. Boş sağlayıcı dönünce
            // `draggingCollectionID` set edilmez ve drop hedefleri
            // (bkz. CollectionReorderDelegate) hiçbir şey yapmaz.
            guard !appState.isSearching, !collection.isUngrouped else { return NSItemProvider() }
            draggingCollectionID = collection.id
            return NSItemProvider(object: collection.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: CollectionReorderDelegate(
                target: collection.id,
                dragging: $draggingCollectionID,
                appState: appState
            )
        )
        .contextMenu {
            if !collection.isUngrouped {
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
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(L10n.t("common.deleteEllipsis"), systemImage: "trash")
                }
            }
        }
    }
}

/// Koleksiyon başlıkları arasında canlı sıralama: sürüklenen başlık başka bir
/// başlığın üzerine gelince yer değiştirir, bırakınca konum sabitlenir.
/// Drop hedefi yalnızca başlıklar olduğu için bir koleksiyon başka bir
/// koleksiyonun İÇİNE bırakılamaz.
struct CollectionReorderDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let appState: AppState

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        appState.moveCollection(dragging, before: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
