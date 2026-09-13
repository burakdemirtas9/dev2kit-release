import SwiftUI
import BoltDockCore

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showingSecrets = false
    @State private var showingEnvironments = false

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
                Group {
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
    @State private var pendingImportSource: AppState.ImportSource = .boltdock
    @State private var showingPostmanImport = false
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var deleteTarget: CollectionModel?
    @State private var draggingCollectionID: UUID?

    /// Sürükleme sırasında diğer koleksiyonlar soluklaşır ve kilitlenir.
    private func isDimmed(_ collectionID: UUID) -> Bool {
        draggingCollectionID != nil && draggingCollectionID != collectionID
    }

    var body: some View {
        @Bindable var state = appState
        List(selection: $state.selectedRequestID) {
            ForEach(appState.workspace.collections) { collection in
                Section {
                    if !appState.isCollectionCollapsed(collection.id) {
                    ForEach(collection.requests) { request in
                        HStack {
                            Text(request.method.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(methodColor(request.method))
                                .frame(width: 44, alignment: .leading)
                            Text(request.name)
                                .lineLimit(1)
                        }
                        .tag(request.id)
                        .contextMenu {
                            Button("Sil", role: .destructive) {
                                appState.deleteRequest(request.id)
                            }
                        }
                        .opacity(isDimmed(collection.id) ? 0.35 : 1)
                        .disabled(draggingCollectionID != nil)
                    }
                    .onMove { source, destination in
                        appState.moveRequests(in: collection.id, from: source, to: destination)
                    }
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
                } header: {
                    HStack(spacing: 4) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                appState.toggleCollectionCollapsed(collection.id)
                            }
                        } label: {
                            Image(systemName: appState.isCollectionCollapsed(collection.id) ? "chevron.right" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(appState.isCollectionCollapsed(collection.id) ? "Genişlet" : "Daralt")
                        Image(systemName: "line.3.horizontal")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(collection.name)
                        Text("\(collection.requests.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .opacity(isDimmed(collection.id) ? 0.35 : 1)
                    .onDrag {
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
        // Başlıklar dışında bir yere bırakılırsa sürükleme durumunu temizle;
        // sıralama zaten hover sırasında canlı yapıldı.
        .onDrop(of: [.text], isTargeted: nil) { _ in
            draggingCollectionID = nil
            return true
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
                    Button("BoltDock Koleksiyonu…") {
                        pendingImportSource = .boltdock
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
                    } label: {
                        Label("İçe Aktar", systemImage: "square.and.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Koleksiyon içe aktar (BoltDock veya Postman)")
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
        .frame(minWidth: 220)
    }

    private func methodColor(_ method: HTTPMethod) -> Color {
        switch method {
        case .get: return Theme.up
        case .post: return Theme.warning
        case .put, .patch: return Theme.purple
        case .delete: return Theme.down
        case .head, .options: return Theme.muted
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

struct EnvironmentPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Picker("Environment", selection: $state.workspace.activeEnvironmentID) {
            Text("Environment Yok").tag(UUID?.none)
            ForEach(appState.workspace.environments) { environment in
                Text(environment.name).tag(UUID?.some(environment.id))
            }
        }
        .onChange(of: appState.workspace.activeEnvironmentID) {
            appState.persist()
        }
    }
}
