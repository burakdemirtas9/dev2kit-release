import SwiftUI
import Dev2KitCore

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var deleteTarget: SidebarSnapshot.Collection?
    @State private var teamDeleteTarget: SidebarSnapshot.Collection?
    @State private var folderPrompt: SidebarFolderPrompt?
    @State private var folderText = ""
    @State private var deleteRequestTargets: Set<UUID> = []
    @State private var draggingCollectionID: UUID?
    @State private var tokenFactoryDropTargeted = false
    @FocusState private var searchFocused: Bool

    /// Bırakılan satır kimliklerini okuyup Token Factory'ye kopyalar. Yük
    /// uygulamaya özel (`InternalDrag`); yalnızca workspace'teki normal
    /// isteklere karşılık gelen kimlikler işlenir, gerisi yok sayılır.
    private func copyDroppedRequests(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var ids = Set<UUID>()
            for provider in providers {
                if let id = await InternalDrag.loadID(from: provider) {
                    ids.insert(id)
                }
            }
            appState.copyToTokenFactory(ids)
        }
    }

    /// Sürükleme sırasında diğer koleksiyonlar soluklaşır ve kilitlenir.
    private func isDimmed(_ collectionID: UUID) -> Bool {
        draggingCollectionID != nil && draggingCollectionID != collectionID
    }

    /// Liste seçimi. Boşa çekilen seçim yok sayılır.
    ///
    /// Sebep: filtreleme sırasında AÇIK olan istek listeden düşerse AppKit
    /// tablo seçimini boşaltıp bunu binding'e geri yazar — kullanıcı ⌘F ile
    /// arama yazmaya başlayınca düzenlediği istek kapanırdı. İstek silme gibi
    /// gerçek temizleme yolları `selectedRequestID`'yi doğrudan set ettiği
    /// için onlar etkilenmez.
    /// `order`: görünen isteklerin sırası; aktif istek buna göre belirlenir.
    ///
    /// Örnek satırları da listede seçilebilir (satıra gesture bağlanmaz,
    /// UI-KURALLARI §2c): tek başına seçilen örnek açılır; istek seçimine
    /// karışan örnek kimlikleri yok sayılır.
    /// `exampleOwners`: görünen örneklerin sahibi olan istekler.
    private func listSelection(order: [UUID], exampleOwners: [UUID: UUID]) -> Binding<Set<UUID>> {
        Binding(
            get: { appState.openExample.map { [$0.exampleID] } ?? appState.selectedRequestIDs },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                if newValue.count == 1, let exampleID = newValue.first, let owner = exampleOwners[exampleID] {
                    appState.openExample(AppState.ExampleRef(requestID: owner, exampleID: exampleID))
                    return
                }
                // Yalnızca görünen istekler: klasör satırının kimliği seçim sayılmaz.
                let visible = Set(order)
                let requests = newValue.filter { exampleOwners[$0] == nil && visible.contains($0) }
                guard !requests.isEmpty else { return }
                appState.applySelection(requests, order: order)
            }
        )
    }

    /// Arama sırasında daraltılmış koleksiyonlar da açılır: aksi halde eşleşen
    /// istekler gizli kalırdı. Kullanıcının daraltma tercihine dokunulmaz,
    /// yalnızca gösterim sırasında yok sayılır.
    private func isCollapsedForDisplay(_ collectionID: UUID) -> Bool {
        !appState.isSearching && appState.isCollectionCollapsed(collectionID)
    }


    /// Liste, altında Token Factory ve alt çubuk.
    ///
    /// Alt kısım `safeAreaInset` DEĞİL, listenin altında ayrı bir bölge: inset
    /// içinde liste onun arkasına kayıyor, yarı saydam panelin içinden uzun
    /// koleksiyonların satırları görünüyordu. Böylece liste panelin başladığı
    /// yerde biter.
    var body: some View {
        VStack(spacing: 0) {
            searchField(hitCount: searchHitCount)
            requestList
            TokenFactoryPanel(isDropTargeted: tokenFactoryDropTargeted)
                // Yukarıdan sürüklenen istekler bırakılınca KOPYALANIR
                // (bkz. AppState.copyToTokenFactory). Koleksiyon başlığı
                // da kimlik taşır; istek olmadığı için yok sayılır ama
                // sürükleme durumu yine temizlenmeli.
                .onDrop(of: [InternalDrag.type], isTargeted: $tokenFactoryDropTargeted) { providers in
                    draggingCollectionID = nil
                    copyDroppedRequests(providers)
                    return true
                }
            SidebarBottomBar()
        }
        // Workbench'teki gibi camlı, içerikten ayrışan sütun (çizgi yerine).
        .background { SidebarMaterial().ignoresSafeArea() }
    }

    private var searchHitCount: Int {
        appState.sidebarCollections
            .filter { !($0.isUngrouped && $0.requests.isEmpty) }
            .reduce(0) { $0 + $1.requests.count }
    }

    @ViewBuilder private var requestList: some View {
        // Filtreleme render başına bir kez: boş-sonuç kontrolü, liste ve
        // eşleşme sayacı aynı sonucu kullanır.
        // Boş "Koleksiyonsuz" kabı gösterilmez: içinde istek yokken bölüm yoktur.
        // Token Factory listede değil, altta kendi bölümünde (TokenFactoryPanel).
        // Kenar çubuğu workspace'i değil özeti okur (`SidebarSnapshot`):
        // yazarken (header, gövde, URL) liste yeniden kurulmaz (2026-11-01).
        let matches = appState.sidebarCollections.filter { !($0.isUngrouped && $0.requests.isEmpty) }
        // Kirli istekler özette, workspace değişince bir kez hesaplanmış.
        let dirty = appState.sidebarSnapshot.dirty
        // ⇧/⌘ ile seçilen aralığın hangi uçta bittiğini bilmek için görünen sıra.
        let visibleOrder = matches.flatMap { $0.requests.map(\.id) }
        let exampleOwners = RequestTreeRows.exampleOwners(in: matches.flatMap(\.requests))
        let firstOwn = firstOwnID(in: matches)
        ScrollViewReader { proxy in
        List(selection: listSelection(order: visibleOrder, exampleOwners: exampleOwners)) {
            // Kurum oturumu ve collection'ları (2026-11-11). Kurum collection'ları
            // aşağıdaki listede kendilerinin önünde durur. Bölüm yalnızca
            // kullanılırken üstte: girişsizken (kurum collection'ı, bildirim
            // yokken) listenin sonuna iner, en değerli yeri tutmaz.
            if !appState.isSearching, teamSectionOnTop { TeamSidebarSection() }
            if appState.isSearching, matches.isEmpty {
                Text(L10n.t("sidebar.search.noMatch", appState.searchQuery))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
            ForEach(matches) { collection in
                // Salt okunur kurum collection'ı: yeni istek, sıralama, taşıma yok.
                let readOnly = collection.team.map { !$0.canEdit } ?? false
                Section {
                    if !isCollapsedForDisplay(collection.id) {
                        // Klasör başlıkları, istekler ve açık örnekleri (`SidebarCollectionRows`).
                        SidebarCollectionRows(
                            collection: collection,
                            dirty: dirty,
                            readOnly: readOnly,
                            isDimmed: isDimmed(collection.id),
                            isDraggingCollection: draggingCollectionID != nil,
                            onDeleteRequests: { deleteRequestTargets = $0 },
                            onFolderPrompt: { prompt in
                                if case .rename(_, let path) = prompt { folderText = path.last ?? "" } else { folderText = "" }
                                folderPrompt = prompt
                            }
                        )
                        // Filtreliyken gizlenir: arama sonucunun arasında duran
                        // "Yeni İstek" satırları sonucu okunmaz hale getiriyor.
                        if appState.teamLoadingIDs.contains(collection.id) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(L10n.t("team.loading")).font(.secondaryText).foregroundStyle(.secondary)
                            }
                        }
                        // "Yeni Request" satırı yok (2026-11-15): her collection'ın
                        // altında tekrar ediyordu. Başlıkta, üzerine gelince çıkan
                        // artı ve sağ tık menüsü (`SidebarCollectionHeader`).
                    }
                } header: {
                    SidebarCollectionHeader(
                        collection: collection,
                        isCollapsed: isCollapsedForDisplay(collection.id),
                        containsDirtyRequest: isCollapsedForDisplay(collection.id)
                            && collection.requests.contains(where: { dirty.contains($0.id) }),
                        isDimmed: isDimmed(collection.id),
                        draggingCollectionID: $draggingCollectionID,
                        onRename: {
                            renameText = collection.name
                            renameTargetID = collection.id
                        },
                        isFirstOwn: collection.team == nil && collection.id == firstOwn,
                        canAddRequest: !appState.isSearching && !readOnly,
                        onDelete: {
                            if collection.team != nil { teamDeleteTarget = collection } else { deleteTarget = collection }
                        }
                    )
                }
            }
            if !appState.isSearching, !teamSectionOnTop { TeamSidebarSection() }
        }
        // Yeni oluşturulan istek listede görünür olsun.
        .onChange(of: appState.sidebarRevealID) { _, id in
            guard let id else { return }
            DispatchQueue.main.async {
                withAnimation { proxy.scrollTo(id, anchor: .center) }
                appState.sidebarRevealID = nil
            }
        }
        }
        // ⌫: seçili istekleri sil. Kalıcı işlem olduğu için onay kutusundan geçer.
        .onDeleteCommand {
            // Açık örnek seçiliyse yalnızca o örnek silinir (onaylı).
            if let example = appState.openExample {
                appState.exampleDeleteTarget = example
                return
            }
            guard !appState.selectedRequestIDs.isEmpty else { return }
            deleteRequestTargets = appState.selectedRequestIDs
        }
        // Başlıklar dışında bir yere bırakılırsa sürükleme durumunu temizle;
        // sıralama zaten hover sırasında canlı yapıldı.
        .onDrop(of: [InternalDrag.type], isTargeted: nil) { _ in
            draggingCollectionID = nil
            return true
        }
        // Kenar çubuğu stili: Workbench'teki gibi camlı zemin ve sıkı satırlar.
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
        .scrollContentBackground(.hidden)
        // ⌘F menü komutu view'ın odak durumuna erişemiyor; AppState'teki sayaç
        // üzerinden köprülenir.
        .onChange(of: appState.searchFocusRequest) {
            searchFocused = true
        }
        .alert(
            folderPromptTitle,
            isPresented: Binding(
                get: { folderPrompt != nil },
                set: { if !$0 { folderPrompt = nil } }
            ),
            presenting: folderPrompt
        ) { prompt in
            TextField(L10n.t("folder.name.placeholder"), text: $folderText)
                .inputLimit(.name)
            switch prompt {
            case .new(let collection, let ids):
                Button(L10n.t("folder.new.confirm")) {
                    // "A/B" iç içe klasör demektir.
                    let path = folderText.split(separator: "/").map(String.init)
                    if !RequestFolders.sanitized(path).isEmpty {
                        appState.placeRequests(ids, in: collection, folder: path)
                    }
                    folderPrompt = nil
                }
            case .rename(let collection, let path):
                Button(L10n.t("collection.rename.confirm")) {
                    appState.renameFolder(path, to: folderText, in: collection)
                    folderPrompt = nil
                }
            }
            Button(L10n.t("common.cancel"), role: .cancel) { folderPrompt = nil }
        } message: { prompt in
            if case .new = prompt { Text(L10n.t("folder.new.message")) }
        }
        .alert(
            L10n.t("collection.rename.title"),
            isPresented: Binding(
                get: { renameTargetID != nil },
                set: { if !$0 { renameTargetID = nil } }
            )
        ) {
            TextField(L10n.t("collection.name.placeholder"), text: $renameText)
                .inputLimit(.name)
            Button(L10n.t("collection.rename.confirm")) {
                if let id = renameTargetID {
                    appState.renameCollection(id, to: renameText)
                }
                renameTargetID = nil
            }
            Button(L10n.t("common.cancel"), role: .cancel) { renameTargetID = nil }
        }
        .alert(
            L10n.t("common.deleteNamed.title", deleteTarget?.name ?? ""),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button(L10n.t("collection.delete"), role: .destructive) {
                if let target = deleteTarget {
                    appState.deleteCollection(target.id)
                }
                deleteTarget = nil
            }
            Button(L10n.t("common.cancel"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(L10n.plural("collection.delete.message", count: deleteTarget?.totalRequests ?? 0))
        }
        .alert(
            L10n.t("team.delete.title", teamDeleteTarget?.name ?? ""),
            isPresented: Binding(
                get: { teamDeleteTarget != nil },
                set: { if !$0 { teamDeleteTarget = nil } }
            )
        ) {
            Button(L10n.t("team.delete.confirm"), role: .destructive) {
                if let target = teamDeleteTarget {
                    Task { await appState.teamDelete(target.id) }
                }
                teamDeleteTarget = nil
            }
            Button(L10n.t("common.cancel"), role: .cancel) { teamDeleteTarget = nil }
        } message: {
            Text(L10n.t("team.delete.message"))
        }
        .alert(
            deleteRequestTitle,
            isPresented: Binding(
                get: { !deleteRequestTargets.isEmpty },
                set: { if !$0 { deleteRequestTargets = [] } }
            )
        ) {
            Button(deleteRequestTargets.count > 1 ? L10n.plural("request.deleteMany", count: deleteRequestTargets.count) : L10n.t("request.delete"), role: .destructive) {
                appState.deleteRequests(deleteRequestTargets)
                deleteRequestTargets = []
            }
            Button(L10n.t("common.cancel"), role: .cancel) { deleteRequestTargets = [] }
        } message: {
            Text(L10n.t("common.deletePermanent"))
        }
        .sheet(isPresented: Bindable(appState).showingTeamLogin) {
            TeamLoginSheet()
        }
        .alert(
            L10n.t("team.conflict.title"),
            isPresented: Binding(
                get: { appState.teamConflictID != nil },
                set: { if !$0 { appState.teamConflictID = nil } }
            ),
            presenting: appState.teamConflictID
        ) { id in
            Button(L10n.t("team.conflict.reload"), role: .destructive) {
                Task { await appState.teamResolveConflictByReloading(id) }
            }
            Button(L10n.t("team.conflict.overwrite")) {
                Task { await appState.teamResolveConflictByOverwriting(id) }
            }
            Button(L10n.t("common.cancel"), role: .cancel) { appState.teamConflictID = nil }
        } message: { _ in
            Text(L10n.t("team.conflict.message"))
        }
        .alert(
            L10n.t("team.remoteChanged.title"),
            isPresented: Binding(
                get: { appState.teamRemoteChangedIDs.first != nil && appState.teamConflictID == nil },
                set: { _ in }
            ),
            presenting: appState.teamRemoteChangedIDs.first
        ) { id in
            Button(L10n.t("team.conflict.reload"), role: .destructive) {
                Task { await appState.teamResolveRemoteChange(id, loadServer: true) }
            }
            Button(L10n.t("team.remoteChanged.keep"), role: .cancel) {
                Task { await appState.teamResolveRemoteChange(id, loadServer: false) }
            }
        } message: { id in
            let info = appState.teamCatalog.entries[id]
            Text(L10n.t("team.remoteChanged.message", info?.summary.name ?? "", info?.summary.updatedBy ?? "?"))
        }
        .frame(minWidth: 220)
    }

    private var folderPromptTitle: String {
        if case .rename = folderPrompt { return L10n.t("folder.rename.title") }
        return L10n.t("folder.new.title")
    }

    /// Kurum bölümü üstte mi: oturum açıkken, önbellekten kurum collection'ı
    /// gösterilirken ya da okunacak bir bildirim varken.
    private var teamSectionOnTop: Bool {
        appState.teamIdentity != nil || !appState.teamCatalog.entries.isEmpty || appState.teamNotice != nil
    }

    /// Kurum collection'ları varken kendi collection'larının ilki "Collection'larım"
    /// başlığını taşır. Liste kurum collection'larıyla başladığı için ilk eşleşme.
    private func firstOwnID(in collections: [SidebarSnapshot.Collection]) -> UUID? {
        guard collections.first?.team != nil else { return nil }
        return collections.first(where: { $0.team == nil })?.id
    }

    /// Silme onayının başlığı: tek istekte adı, çoklu seçimde sayısı.
    private var deleteRequestTitle: String {
        if deleteRequestTargets.count == 1, let id = deleteRequestTargets.first {
            return L10n.t("common.deleteNamed.title", appState.sidebarSnapshot.requestName(id) ?? "")
        }
        return L10n.plural("request.deleteMany.title", count: deleteRequestTargets.count)
    }

    /// Sidebar filtresi. ⌘F odaklanır, Esc temizler, ⏎ ilk sonucu seçer.
    /// Görünüm Workbench'in arama kutusuyla aynı: gömme, yuvarlak alan.
    private func searchField(hitCount: Int) -> some View {
        @Bindable var state = appState
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                TextField(L10n.t("sidebar.search.placeholder"), text: $state.searchQuery)
                    .inputLimit(.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { selectFirstHit() }
                    // Esc: alanı boşaltır ama odağı bırakmaz — kullanıcı
                    // genelde yeni bir arama yazmak için basıyor.
                    // Alan boşken tuş tüketilmez ki Esc'in başka anlamları
                    // (sheet kapatma vb.) çalışmaya devam etsin.
                    .onKeyPress(.escape) {
                        guard !appState.searchQuery.isEmpty else { return .ignored }
                        appState.clearSearch()
                        return .handled
                    }
                if !appState.searchQuery.isEmpty {
                    Text("\(hitCount)")
                        .font(.tinyText.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(L10n.plural("sidebar.search.hits", count: hitCount))
                    Button {
                        appState.clearSearch()
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .iconHitTarget(20)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("sidebar.search.clear"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .inputChrome(isFocused: searchFocused)
            .padding(8)
        }
    }

    /// Arama alanında ⏎: ilk eşleşen isteği seçer, odağı listeye bırakmadan.
    /// Amaç "yaz → enter → istek açıldı" akışı; ad tam bilinmese de çalışır.
    private func selectFirstHit() {
        guard let hit = appState.firstSearchHit else { return }
        appState.selectedRequestID = hit.id
    }
}

