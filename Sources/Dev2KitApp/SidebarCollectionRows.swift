import SwiftUI
import Dev2KitCore

/// Kenar çubuğunda klasörle ilgili ad sorusu (kutu `SidebarView`'da).
enum SidebarFolderPrompt: Equatable {
    /// Seçili istekler yeni bir klasöre taşınacak.
    case new(collection: UUID, ids: Set<UUID>)
    case rename(collection: UUID, path: [String])
}

/// Bir collection'ın satırları: klasör başlıkları, istekler ve açık
/// örnekleri. `SidebarView`'dan ayrıldı (2026-11-15): klasör satırlarıyla
/// birlikte tek ifade derleyicinin tip denetimini aşıyordu.
///
/// Satır listesi ve klasör yolları collection başına BİR KEZ kurulur; satır
/// gövdelerinde tarama yok (UI-KURALLARI §3). Kurallar Core'da:
/// `RequestTreeRows` (satırlar, sürükle-bırak yerleşimi), `RequestFolders`.
struct SidebarCollectionRows: View {
    @Environment(AppState.self) private var appState
    let collection: SidebarSnapshot.Collection
    let dirty: Set<UUID>
    /// Salt okunur kurum collection'ı: sıralama, taşıma, klasör işlemi yok.
    let readOnly: Bool
    let isDimmed: Bool
    let isDraggingCollection: Bool
    let onDeleteRequests: (Set<UUID>) -> Void
    let onFolderPrompt: (SidebarFolderPrompt) -> Void

    /// Klasör düzeyi başına girinti.
    static let indent: CGFloat = 12

    var body: some View {
        let requestsByID = Dictionary(collection.requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Aramada katlı klasörler de açık gösterilir (collection'lar gibi).
        let rows = RequestTreeRows.rows(
            for: collection.requests,
            expanded: appState.expandedExampleRequestIDs,
            collapsedFolders: appState.isSearching ? [] : appState.collapsedFolderIDs,
            folderID: { RequestFolders.rowID(collection: collection.id, path: $0) }
        )
        let folderPaths = readOnly ? [] : RequestFolders.paths(in: collection.requests)
        ForEach(rows) { row in
            rowView(row, requestsByID: requestsByID, folderPaths: folderPaths)
                .opacity(isDimmed ? 0.35 : 1)
                .disabled(isDraggingCollection)
        }
        .onMove { source, destination in
            // Filtreliyken indeksler GÖRÜNEN listeye göre gelir; `moveDisabled`
            // ile birlikte ikinci hat. Yerleşim kimlikle: katlı klasördeki
            // gizli istekler hesabı bozmaz.
            guard !appState.isSearching, !readOnly,
                  let placement = RequestTreeRows.placement(
                      source: source, destination: destination, in: rows,
                      folderOf: { requestsByID[$0]?.folder ?? [] })
            else { return }
            appState.placeRequests(placement.ids, in: collection.id, folder: placement.folder, before: placement.before)
        }
    }

    @ViewBuilder
    private func rowView(_ row: RequestTreeRows.Row, requestsByID: [UUID: SidebarSnapshot.Request],
                         folderPaths: [[String]]) -> some View {
        switch row {
        case .request(let id):
            if let request = requestsByID[id] {
                SidebarRequestRow(
                    request: request,
                    collection: collection,
                    isDirty: dirty.contains(request.id),
                    examplesExpanded: appState.areExamplesExpanded(request.id),
                    folderPaths: folderPaths,
                    canOrganize: !readOnly && !appState.isSearching,
                    onNewFolder: { onFolderPrompt(.new(collection: collection.id, ids: $0)) },
                    onDelete: onDeleteRequests
                )
                .padding(.leading, CGFloat(request.folder.count) * Self.indent)
                .tag(request.id)
                .moveDisabled(appState.isSearching || readOnly)
                // Token Factory paneline bırakılınca kopyalanabilsin diye satır
                // kimliğini taşır; liste içi sıralama (`onMove`) bundan etkilenmez.
                // Sürüklenenler (seçimdeyse tüm seçim) başlığa bırakma için
                // AppState'e de yazılır (`draggedRequestIDs`).
                .teamRegionBackground(collection.team != nil)
                .itemProvider {
                    let id = request.id
                    MainActor.assumeIsolated {
                        appState.draggedRequestIDs = MultiSelection.targets(
                            forContextMenuOn: id, selection: appState.selectedRequestIDs)
                    }
                    return InternalDrag.provider(for: id)
                }
            }
        case .example(let requestID, let exampleID):
            if let owner = requestsByID[requestID], let example = owner.examples.first(where: { $0.id == exampleID }) {
                SidebarExampleRow(
                    ref: AppState.ExampleRef(requestID: requestID, exampleID: exampleID),
                    example: example
                )
                .padding(.leading, CGFloat(owner.folder.count) * Self.indent)
                .tag(exampleID)
                .teamRegionBackground(collection.team != nil)
                // Örnek isteğinden ayrılmaz; sürüklenmez.
                .moveDisabled(true)
            }
        case .folder(let id, let path, let count):
            SidebarFolderRow(
                collectionID: collection.id, id: id, path: path, count: count,
                isCollapsed: !appState.isSearching && appState.isFolderCollapsed(id),
                canOrganize: !readOnly && !appState.isSearching,
                onRename: { onFolderPrompt(.rename(collection: collection.id, path: path)) }
            )
            .padding(.leading, CGFloat(path.count - 1) * Self.indent)
            .tag(id)
            .teamRegionBackground(collection.team != nil)
            // Klasör satırı seçilmez ve sürüklenmez; yalnızca açar/katlar.
            .selectionDisabled(true)
            .moveDisabled(true)
        }
    }
}

/// Klasör başlığı satırı: aç/katla, sağ tık menüsü. Tıklama hedefi satırın
/// tamamı ve bir `Button` (UI-KURALLARI §2c: satıra gesture bağlanmaz).
struct SidebarFolderRow: View {
    @Environment(AppState.self) private var appState
    let collectionID: UUID
    let id: UUID
    let path: [String]
    let count: Int
    let isCollapsed: Bool
    let canOrganize: Bool
    let onRename: () -> Void

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { appState.toggleFolderCollapsed(id) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.tinyText.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarRequestRow.toggleWidth, height: SidebarRequestRow.toggleHeight)
                Image(systemName: "folder")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                Text(path.last ?? "")
                    .lineLimit(1)
                Text("\(count)")
                    .font(.tinyText)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Aramada klasörler zorla açık; katlamak hiçbir şey değiştirmezdi.
        .disabled(appState.isSearching)
        .help(isCollapsed ? L10n.t("folder.expand") : L10n.t("folder.collapse"))
        .accessibilityLabel(L10n.t("folder.accessibility", path.joined(separator: " / "), L10n.number(count)))
        .contextMenu {
            if canOrganize {
                Button {
                    appState.addRequest(to: collectionID, folder: path)
                } label: {
                    Label(L10n.t("folder.newRequest"), systemImage: "plus")
                }
                Button {
                    onRename()
                } label: {
                    Label(L10n.t("collection.renameEllipsis"), systemImage: "pencil")
                }
                Divider()
                Button {
                    appState.removeFolder(path, in: collectionID)
                } label: {
                    Label(L10n.t("folder.remove"), systemImage: "folder.badge.minus")
                }
            }
        }
    }
}
