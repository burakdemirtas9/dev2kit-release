import SwiftUI
import SecoraCore

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showingSecrets = false
    @State private var showingEnvironments = false
    @State private var showingCookies = false
    @State private var showingHistory = false
    @State private var showingTLS = false

    private static let sidebarWidthKey = "sidebarWidth"
    private static let minSidebarWidth: CGFloat = 220
    private static let splitSpace = "splitContainer"

    /// İlk açılışta minimum; sonraki açılışlarda kullanıcının bıraktığı genişlik.
    @State private var sidebarWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: ContentView.sidebarWidthKey)
        return stored >= ContentView.minSidebarWidth ? CGFloat(stored) : ContentView.minSidebarWidth
    }()
    @State private var isHoveringDivider = false

    /// Genişlik sınırları: alt 220, üst içerik genişliği — ve detay paneline
    /// en az 480px kalacak şekilde pencereye göre kırpılır.
    private func effectiveSidebarWidth(totalWidth: CGFloat) -> CGFloat {
        let upper = max(Self.minSidebarWidth, min(appState.sidebarMaxWidth, totalWidth - 489))
        return min(max(sidebarWidth, Self.minSidebarWidth), upper)
    }

    var body: some View {
        @Bindable var state = appState
        // Genişlik tamamen bizde: HSplitView/NavigationSplitView ayraç konumunu
        // dışarıdan vermeye izin vermiyor (ilk açılış + kalıcılık için gerekli).
        GeometryReader { geometry in
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: effectiveSidebarWidth(totalWidth: geometry.size.width))
                sidebarDivider(totalWidth: geometry.size.width)
                VStack(spacing: 0) {
                    if !appState.openTabs.isEmpty {
                        RequestTabBar()
                        Divider()
                    }
                    if let requestBinding = appState.selectedRequest {
                        RequestDetailView(request: requestBinding)
                    } else {
                        ContentUnavailableView(
                            "İstek Seç",
                            systemImage: "paperplane",
                            description: Text("Soldan bir istek seç veya yeni bir istek oluştur.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: Self.splitSpace)
            // Sürüklerken örtük animasyon genişliği "kovalayınca" titreme oluyor.
            .animation(nil, value: sidebarWidth)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                EnvironmentPicker()
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showingEnvironments = true
                } label: {
                    Label("Environment'lar", systemImage: "globe")
                }
                .help("Environment oluştur ve düzenle")
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Görünüm", selection: $state.appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Görünüm", systemImage: appState.appearanceMode.icon)
                }
                .help("Açık/koyu görünüm")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showingHistory = true
                } label: {
                    Label("Geçmiş", systemImage: "clock.arrow.circlepath")
                }
                .help("Gönderilen isteklerin kaydı (⌘Y)")
                .keyboardShortcut("y", modifiers: .command)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showingCookies = true
                } label: {
                    Label {
                        Text("Çerezler")
                    } icon: {
                        CookieIcon().frame(width: 15, height: 15)
                    }
                }
                .help("Oturum çerezlerini görüntüle ve temizle")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showingTLS = true
                } label: {
                    Label("TLS", systemImage: "lock.shield")
                }
                .help("Kurum CA'sı ve istemci sertifikası profilleri")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showingSecrets = true
                } label: {
                    Label("Secrets", systemImage: "key.fill")
                }
                .help("Keychain'deki secret'ları yönet")
            }
        }
        .sheet(isPresented: $showingSecrets) {
            SecretsView()
        }
        .sheet(isPresented: $showingEnvironments) {
            EnvironmentsView()
        }
        .sheet(isPresented: $showingCookies) {
            CookiesView()
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView()
        }
        .sheet(isPresented: $showingTLS) {
            TLSProfilesView()
        }
        .alert("Hata", isPresented: .constant(state.saveError != nil)) {
            Button("Tamam") { state.saveError = nil }
        } message: {
            Text(state.saveError ?? "")
        }
        .alert("Koleksiyon Aktarımı", isPresented: .constant(state.portingMessage != nil)) {
            Button("Tamam") { state.portingMessage = nil }
        } message: {
            Text(state.portingMessage ?? "")
        }
    }

    /// Sürüklenebilir dikey ayraç: 1px çizgi + 9px görünmez tutma alanı.
    /// Bırakınca genişlik UserDefaults'a yazılır, sonraki açılışta geri gelir.
    private func sidebarDivider(totalWidth: CGFloat) -> some View {
        ZStack {
            Color.clear
                .frame(width: 9)
                .contentShape(Rectangle())
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        // push/pop dengesiz kalırsa imleç yığını bozuluyor (ayraç üstündeyken
        // pencere değişince "pop" gelmeyebiliyor); bayrakla eşleştiriliyor.
        .onHover { hovering in
            guard hovering != isHoveringDivider else { return }
            isHoveringDivider = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHoveringDivider {
                isHoveringDivider = false
                NSCursor.pop()
            }
        }
        // translation yerine konteynerdeki mutlak konum kullanılıyor: ayraç
        // sürüklendikçe kendi koordinat uzayı da kaydığı için translation
        // geri besleme yapıp titremeye yol açıyordu.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.splitSpace))
                .onChanged { value in
                    let upper = max(Self.minSidebarWidth, min(appState.sidebarMaxWidth, totalWidth - 489))
                    sidebarWidth = min(max(value.location.x, Self.minSidebarWidth), upper)
                }
                .onEnded { _ in
                    UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
                }
        )
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var showingImporter = false
    @State private var pendingImportSource: AppState.ImportSource = .secora
    @State private var showingPostmanImport = false
    @State private var showingCurlImport = false
    @State private var showingKibanaImport = false
    @State private var showingOpenAPIImport = false
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var deleteTarget: CollectionModel?
    @State private var deleteRequestTarget: RequestModel?
    @State private var draggingCollectionID: UUID?
    @FocusState private var searchFocused: Bool

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
    private var listSelection: Binding<UUID?> {
        Binding(
            get: { appState.selectedRequestID },
            set: { newValue in
                guard let newValue else { return }
                appState.selectedRequestID = newValue
            }
        )
    }

    /// Arama sırasında daraltılmış koleksiyonlar da açılır: aksi halde eşleşen
    /// istekler gizli kalırdı. Kullanıcının daraltma tercihine dokunulmaz,
    /// yalnızca gösterim sırasında yok sayılır.
    private func isCollapsedForDisplay(_ collectionID: UUID) -> Bool {
        !appState.isSearching && appState.isCollectionCollapsed(collectionID)
    }

    var body: some View {
        // Filtreleme render başına bir kez: boş-sonuç kontrolü, liste ve
        // eşleşme sayacı aynı sonucu kullanır.
        // Boş "Koleksiyonsuz" kabı gösterilmez: içinde istek yokken bölüm yoktur.
        let matches = appState.visibleCollections.filter { !($0.collection.isUngrouped && $0.requests.isEmpty) }
        List(selection: listSelection) {
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
                        HStack {
                            Text(request.method.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.color(for: request.method))
                                .frame(width: 44, alignment: .leading)
                            Text(request.name)
                                .lineLimit(1)
                            if appState.isDirty(request.id) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(Theme.warning)
                                    .help("Son gönderildiği halden farklı")
                            }
                        }
                        .tag(request.id)
                        // Tek tıklama önizler (liste seçimi), çift tıklama sekmeyi kalıcı yapar.
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            appState.pinTab(request.id)
                        })
                        .contextMenu {
                            Button {
                                appState.duplicateRequest(request.id)
                            } label: {
                                Label("Çoğalt", systemImage: "plus.square.on.square")
                            }
                            let targets = appState.workspace.regularCollections.filter { $0.id != collection.id }
                            if !targets.isEmpty {
                                Menu {
                                    ForEach(targets) { target in
                                        Button(target.name) {
                                            appState.moveRequest(request.id, toCollection: target.id)
                                        }
                                    }
                                } label: {
                                    Label("Şuraya Taşı", systemImage: "folder")
                                }
                            }
                            if !collection.isUngrouped {
                                Button {
                                    appState.removeFromCollection(request.id)
                                } label: {
                                    Label("Koleksiyondan Çıkar", systemImage: "tray")
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                deleteRequestTarget = request
                            } label: {
                                Label("Sil…", systemImage: "trash")
                            }
                        }
                        .opacity(isDimmed(collection.id) ? 0.35 : 1)
                        .disabled(draggingCollectionID != nil)
                        .moveDisabled(appState.isSearching)
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
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity(isDimmed(collection.id) ? 0.35 : 1)
                        .disabled(draggingCollectionID != nil)
                    }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                appState.toggleCollectionCollapsed(collection.id)
                            }
                        } label: {
                            Image(systemName: isCollapsedForDisplay(collection.id) ? "chevron.right" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // Aramada gösterim zorla açık olduğu için düğme yanıltıcı
                        // olurdu: basınca hiçbir şey değişmiyormuş gibi görünür.
                        .disabled(appState.isSearching)
                        .help(appState.isSearching
                              ? "Arama sırasında tüm koleksiyonlar açık"
                              : (appState.isCollectionCollapsed(collection.id) ? "Genişlet" : "Daralt"))
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
                        if isCollapsedForDisplay(collection.id),
                           appState.hasDirtyRequest(in: collection) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(Theme.warning)
                                .help("İçinde son gönderildiğinden farklı istek var")
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .opacity(isDimmed(collection.id) ? 0.35 : 1)
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
                            renameText = collection.name
                            renameTargetID = collection.id
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
                            deleteTarget = collection
                        } label: {
                            Label("Sil…", systemImage: "trash")
                        }
                        }
                    }
                }
            }
        }
        // Başlıklar dışında bir yere bırakılırsa sürükleme durumunu temizle;
        // sıralama zaten hover sırasında canlı yapıldı.
        .onDrop(of: [.text], isTargeted: nil) { _ in
            draggingCollectionID = nil
            return true
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            searchBar(hitCount: RequestSearch.totalRequests(in: matches))
        }
        // ⌘F menü komutu view'ın odak durumuna erişemiyor; AppState'teki sayaç
        // üzerinden köprülenir.
        .onChange(of: appState.searchFocusRequest) {
            searchFocused = true
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Button {
                        appState.addCollection()
                    } label: {
                        Label("Yeni Koleksiyon", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    Menu {
                    Button("Secora Koleksiyonu…") {
                        pendingImportSource = .secora
                        showingImporter = true
                    }
                    Divider()
                    Button("Postman'den Otomatik Al…") {
                        showingPostmanImport = true
                    }
                    Button("Postman Dosyası…") {
                        pendingImportSource = .postman
                        showingImporter = true
                    }
                    Divider()
                    Button("cURL'den İstek…") {
                        showingCurlImport = true
                    }
                    Button("Kibana Logundan İstek…") {
                        showingKibanaImport = true
                    }
                    Divider()
                    Button("Swagger / OpenAPI Adresinden…") {
                        showingOpenAPIImport = true
                    }
                    } label: {
                        Label("İçe Aktar", systemImage: "square.and.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Koleksiyon ya da istek içe aktar (Secora, Postman, cURL, Kibana, OpenAPI)")
                }
                .padding(8)
            }
            .background(.bar)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json]
        ) { result in
            if case .success(let url) = result {
                appState.importCollection(from: url, source: pendingImportSource)
            }
        }
        .sheet(isPresented: $showingPostmanImport) {
            PostmanImportView()
        }
        .sheet(isPresented: $showingCurlImport) {
            CurlImportView()
        }
        .sheet(isPresented: $showingKibanaImport) {
            KibanaImportView()
        }
        .sheet(isPresented: $showingOpenAPIImport) {
            OpenAPIImportView()
        }
        .sheet(item: Binding(
            get: { appState.pendingImport },
            set: { appState.pendingImport = $0 }
        )) { pending in
            ImportReviewView(
                items: pending.items,
                onConfirm: {
                    appState.pendingImport = nil
                    appState.portingMessage = appState.commitImport(pending.items)
                },
                onCancel: { appState.pendingImport = nil }
            )
        }
        .alert(
            "Koleksiyonu Yeniden Adlandır",
            isPresented: Binding(
                get: { renameTargetID != nil },
                set: { if !$0 { renameTargetID = nil } }
            )
        ) {
            TextField("Koleksiyon adı", text: $renameText)
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
            "İsteği Sil",
            isPresented: Binding(
                get: { deleteRequestTarget != nil },
                set: { if !$0 { deleteRequestTarget = nil } }
            )
        ) {
            Button("Sil", role: .destructive) {
                if let target = deleteRequestTarget {
                    appState.deleteRequest(target.id)
                }
                deleteRequestTarget = nil
            }
            Button("Vazgeç", role: .cancel) { deleteRequestTarget = nil }
        } message: {
            Text("\"\(deleteRequestTarget?.name ?? "")\" kalıcı olarak silinecek.")
        }
        .frame(minWidth: 220)
    }

    /// Sidebar filtresi. ⌘F odaklanır, Esc temizler, ⏎ ilk sonucu seçer.
    private func searchBar(hitCount: Int) -> some View {
        @Bindable var state = appState
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("İstek ara", text: $state.searchQuery)
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
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(hitCount) eşleşen istek")
                    Button {
                        appState.clearSearch()
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Aramayı temizle (Esc)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
        }
        .background(.bar)
    }

    /// Arama alanında ⏎: ilk eşleşen isteği seçer, odağı listeye bırakmadan.
    /// Amaç "yaz → enter → istek açıldı" akışı; ad tam bilinmese de çalışır.
    private func selectFirstHit() {
        guard let hit = appState.firstSearchHit else { return }
        appState.selectedRequestID = hit.id
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

struct EnvironmentPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        // Toolbar içerideki etiketlere "yalnızca ikon" stili uyguluyor; seçenekler
        // düz metin olduğu için seçili değer boş görünüyordu. titleOnly bunu
        // yalnızca bu Picker için geri alır, diğer toolbar düğmeleri ikon kalır.
        Picker("Environment", selection: $state.workspace.activeEnvironmentID) {
            Text("Environment Yok").tag(UUID?.none)
            ForEach(appState.workspace.environments) { environment in
                Text(environment.name).tag(UUID?.some(environment.id))
            }
        }
        .labelStyle(.titleOnly)
        .help("Aktif environment")
        .onChange(of: appState.workspace.activeEnvironmentID) {
            appState.persist()
        }
    }
}
