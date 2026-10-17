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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                if collection.isUngrouped {
                    // Sürüklenemez, yeniden adlandırılamaz: tutamaç yerine kendi simgesi.
                    Image(systemName: "tray")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(collection.name)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Text(collection.name)
                }
                // Aramada "eşleşen/toplam", normalde yalnızca toplam.
                Text(appState.isSearching && match.requests.count != collection.requests.count
                     ? "\(match.requests.count)/\(collection.requests.count)"
                     : "\(collection.requests.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if isCollapsed, containsDirtyRequest {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Theme.warning)
                        .help("İçinde son gönderildiğinden farklı istek var")
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
              ? "Arama sırasında tüm koleksiyonlar açık"
              : (appState.isCollectionCollapsed(collection.id) ? "Genişlet" : "Daralt"))
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
                    Label("Yeniden Adlandır…", systemImage: "pencil")
                }
                Divider()
                Button {
                    appState.exportCollection(collection.id)
                } label: {
                    Label("Dışa Aktar…", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Sil…", systemImage: "trash")
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
