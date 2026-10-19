import SwiftUI
import Dev2KitCore

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var deleteTarget: CollectionModel?
    @State private var deleteRequestTargets: Set<UUID> = []
    @State private var draggingCollectionID: UUID?
    @State private var tokenFactoryDropTargeted = false
    @FocusState private var searchFocused: Bool

    /// Bırakılan satır kimliklerini okuyup Token Factory'ye kopyalar. Metin
    /// başka bir uygulamadan da gelebilir: yalnızca workspace'teki normal
    /// isteklere karşılık gelen kimlikler işlenir, gerisi yok sayılır.
    private func copyDroppedRequests(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var ids = Set<UUID>()
            for provider in providers {
                if let text = await provider.loadText(), let id = UUID(uuidString: text) {
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
    private func listSelection(order: [UUID]) -> Binding<Set<UUID>> {
        Binding(
            get: { appState.selectedRequestIDs },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                appState.applySelection(newValue, order: order)
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
                .onDrop(of: [.text], isTargeted: $tokenFactoryDropTargeted) { providers in
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
        let matches = appState.visibleCollections.filter {
            !($0.collection.isUngrouped && $0.requests.isEmpty) && !$0.collection.isTokenFactory
        }
        return RequestSearch.totalRequests(in: matches)
    }

    @ViewBuilder private var requestList: some View {
        // Filtreleme render başına bir kez: boş-sonuç kontrolü, liste ve
        // eşleşme sayacı aynı sonucu kullanır.
        // Boş "Koleksiyonsuz" kabı gösterilmez: içinde istek yokken bölüm yoktur.
        // Token Factory listede değil, altta kendi bölümünde (TokenFactoryPanel).
        let matches = appState.visibleCollections.filter {
            !($0.collection.isUngrouped && $0.requests.isEmpty) && !$0.collection.isTokenFactory
        }
        // Kirli istekler render başına TEK kez hesaplanır; satırlar ve
        // başlıklar bu kümeye bakar (bkz. AppState.dirtyRequestIDs).
        let dirty = appState.dirtyRequestIDs
        // ⇧/⌘ ile seçilen aralığın hangi uçta bittiğini bilmek için görünen sıra.
        let visibleOrder = matches.flatMap { $0.requests.map(\.id) }
        List(selection: listSelection(order: visibleOrder)) {
            if appState.isSearching, matches.isEmpty {
                Text("\"\(appState.searchQuery)\" için eşleşme yok")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
            ForEach(matches) { match in
                let collection = match.collection
                Section {
                    if !isCollapsedForDisplay(collection.id) {
                        ForEach(match.requests) { request in
                            SidebarRequestRow(
                                request: request,
                                collection: collection,
                                isDirty: dirty.contains(request.id),
                                onDelete: { deleteRequestTargets = $0 }
                            )
                            .tag(request.id)
                            .opacity(isDimmed(collection.id) ? 0.35 : 1)
                            .disabled(draggingCollectionID != nil)
                            .moveDisabled(appState.isSearching)
                            // Token Factory paneline bırakılınca kopyalanabilsin diye
                            // satır kimliğini taşır; liste içi sıralama (`onMove`)
                            // bundan etkilenmez.
                            .itemProvider { NSItemProvider(object: request.id.uuidString as NSString) }
                        }
                        .onMove { source, destination in
                            // Filtreliyken indeksler GÖRÜNEN listeye göre gelir;
                            // gerçek sıradaki konumlara karşılık gelmez, yanlış
                            // isteği taşır. `moveDisabled` ile birlikte ikinci hat.
                            guard !appState.isSearching else { return }
                            appState.moveRequests(in: collection.id, from: source, to: destination)
                        }
                        // Filtreliyken gizlenir: arama sonucunun arasında duran
                        // "Yeni İstek" satırları sonucu okunmaz hale getiriyor.
                        if !appState.isSearching {
                            Button {
                                appState.addRequest(to: collection.id)
                            } label: {
                                Label("Yeni İstek", systemImage: "plus")
                                    .font(.secondaryText)
                                    .rowHitTarget(minHeight: 20)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .opacity(isDimmed(collection.id) ? 0.35 : 1)
                            .disabled(draggingCollectionID != nil)
                        }
                    }
                } header: {
                    SidebarCollectionHeader(
                        match: match,
                        isCollapsed: isCollapsedForDisplay(collection.id),
                        containsDirtyRequest: isCollapsedForDisplay(collection.id)
                            && collection.requests.contains(where: { dirty.contains($0.id) }),
                        isDimmed: isDimmed(collection.id),
                        draggingCollectionID: $draggingCollectionID,
                        onRename: {
                            renameText = collection.name
                            renameTargetID = collection.id
                        },
                        onDelete: { deleteTarget = collection }
                    )
                }
            }
        }
        // ⌫: seçili istekleri sil. Kalıcı işlem olduğu için onay kutusundan geçer.
        .onDeleteCommand {
            guard !appState.selectedRequestIDs.isEmpty else { return }
            deleteRequestTargets = appState.selectedRequestIDs
        }
        // Başlıklar dışında bir yere bırakılırsa sürükleme durumunu temizle;
        // sıralama zaten hover sırasında canlı yapıldı.
        .onDrop(of: [.text], isTargeted: nil) { _ in
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
            "Koleksiyonu Yeniden Adlandır",
            isPresented: Binding(
                get: { renameTargetID != nil },
                set: { if !$0 { renameTargetID = nil } }
            )
        ) {
            TextField("Koleksiyon adı", text: $renameText)
                .inputLimit(.name)
            Button("Kaydet") {
                if let id = renameTargetID {
                    appState.renameCollection(id, to: renameText)
                }
                renameTargetID = nil
            }
            Button("Vazgeç", role: .cancel) { renameTargetID = nil }
        }
        .alert(
            "Koleksiyonu Sil",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Sil", role: .destructive) {
                if let target = deleteTarget {
                    appState.deleteCollection(target.id)
                }
                deleteTarget = nil
            }
            Button("Vazgeç", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("\"\(deleteTarget?.name ?? "")\" ve içindeki \(deleteTarget?.requests.count ?? 0) istek kalıcı olarak silinecek.")
        }
        .alert(
            deleteRequestTargets.count > 1 ? "İstekleri Sil" : "İsteği Sil",
            isPresented: Binding(
                get: { !deleteRequestTargets.isEmpty },
                set: { if !$0 { deleteRequestTargets = [] } }
            )
        ) {
            Button("Sil", role: .destructive) {
                appState.deleteRequests(deleteRequestTargets)
                deleteRequestTargets = []
            }
            Button("Vazgeç", role: .cancel) { deleteRequestTargets = [] }
        } message: {
            if deleteRequestTargets.count == 1, let id = deleteRequestTargets.first {
                Text("\"\(appState.request(withID: id)?.name ?? "")\" kalıcı olarak silinecek.")
            } else {
                Text("\(deleteRequestTargets.count) istek kalıcı olarak silinecek.")
            }
        }
        .frame(minWidth: 220)
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
                TextField("İstek ara", text: $state.searchQuery)
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
                        .help("\(hitCount) eşleşen istek")
                    Button {
                        appState.clearSearch()
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .iconHitTarget(20)
                    }
                    .buttonStyle(.plain)
                    .help("Aramayı temizle (Esc)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.08)))
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

private extension NSItemProvider {
    func loadText() async -> String? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map(String.init))
            }
        }
    }
}
