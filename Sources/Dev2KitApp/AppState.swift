import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Dev2KitCore

// AppState tek sınıf ama beş dosyaya yayılmış durumda. Burada DURUM (stored
// property'ler, tipler, init) ve doğrudan durumla ilgili küçük işler var;
// davranış uzantı dosyalarında:
//
//   AppState+Sending      gönderim, yanıt, güvenlik onayı, token, OAuth2
//   AppState+Porting      içe/dışa aktarma (dosya, Postman, cURL, Kibana, OpenAPI, kaynak tarama)
//   AppState+History      geçmiş kaydı ve geçmişten geri yükleme
//   AppState+Collections  koleksiyon ve environment yönetimi
//   AppState+TLS          güven deposu, TLS profilleri, çerezler
//
// Saf kurallar burada DEĞİL, `Dev2KitCore`'da ve testli: seçim (MultiSelection),
// kirlilik (DirtyRequests), geçmişten geri yükleme (HistoryRestore), öneriler
// (TemplateSuggestions), sekme kuralları (RequestTabs), arama (RequestSearch).

enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: return "Sistem"
        case .light: return "Açık"
        case .dark: return "Koyu"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// İstek düzenleyicinin sekmeleri.
///
/// Neden view'da değil burada: ⌘1…⌘4 menü komutları `RequestDetailView`'ın
/// yerel `@State`'ine erişemez. Yan fayda: istekler arasında geçiş yapınca
/// açık sekme korunur.
enum EditorTab: String, CaseIterable, Identifiable {
    case headers = "Headers"
    case body = "Body"
    case auth = "Auth"
    case params = "Query"

    var id: String { rawValue }
}

/// Uygulamanın tek merkezi durumu. Workspace değişiklikleri debounce'suz,
/// her mutasyondan sonra diske yazılır (MVP için yeterli; dosya küçük).
@Observable
@MainActor
final class AppState {
    var workspace: WorkspaceModel
    /// Seçili istek. Açık değilse önizleme sekmesinde açılır (bkz. Sekmeler).
    var selectedRequestID: UUID? {
        didSet {
            guard selectedRequestID != oldValue else { return }
            if let id = selectedRequestID {
                openTab(id)
                // Tekil seçim yapan yollar (yeni istek, çoğalt, arama sonucu…)
                // çoklu seçimi de sıfırlar; aktif istek zaten kümedeyse dokunulmaz.
                if !selectedRequestIDs.contains(id) { selectedRequestIDs = [id] }
            }
            saveTabs()
        }
    }

    /// Sidebar'da seçili tüm istekler (⇧ aralık, ⌘ tek tek).
    /// Toplu silme/taşıma bu kümeye uygulanır; detayda açık olan
    /// `selectedRequestID` kümenin içinden seçilir (bkz. `MultiSelection`).
    private(set) var selectedRequestIDs: Set<UUID> = []

    /// Listeden gelen yeni seçim kümesini uygular.
    /// `order`: görünen isteklerin sırası — aktif istek buna göre belirlenir.
    func applySelection(_ ids: Set<UUID>, order: [UUID]) {
        let active = MultiSelection.active(current: selectedRequestID, selection: ids, order: order)
        selectedRequestIDs = ids
        selectedRequestID = active
    }

    // MARK: - Sekmeler

    /// Açık istek sekmeleri; kurallar `RequestTabs`'ta (Core, testli).
    private(set) var tabs = RequestTabs()
    var openTabs: [UUID] { tabs.tabs }
    var previewTabID: UUID? { tabs.preview }

    private static let openTabsKey = "openTabs"
    private static let selectedTabKey = "selectedTab"

    private func openTab(_ id: UUID) {
        tabs.open(id)
    }

    /// Sekmeyi kalıcı yapar (açık değilse açar).
    func pinTab(_ id: UUID) {
        tabs.pin(id)
        saveTabs()
    }

    /// Sekmeyi kapatır; seçiliyse sağındaki, yoksa solundaki seçilir.
    func closeTab(_ id: UUID) {
        selectedRequestID = tabs.close(id, selected: selectedRequestID)
        saveTabs()
    }

    func closeOtherTabs(_ id: UUID) {
        selectedRequestID = tabs.closeOthers(keeping: id)
        saveTabs()
    }

    func closeTabsToRight(of id: UUID) {
        selectedRequestID = tabs.closeToRight(of: id, selected: selectedRequestID)
        saveTabs()
    }

    /// Sürükle-bırak: sekmeyi hedefin konumuna taşır.
    func moveTab(_ id: UUID, before targetID: UUID) {
        tabs.move(id, before: targetID)
        saveTabs()
    }

    /// ⌥⌘→ / ⌥⌘←: sonraki / önceki sekme, uçlarda başa sarar.
    func selectAdjacentTab(_ offset: Int) {
        if let next = tabs.adjacent(to: selectedRequestID, offset: offset) { selectedRequestID = next }
    }

    func request(withID id: UUID) -> RequestModel? {
        locateRequest(id).map { workspace.collections[$0.collection].requests[$0.request] }
    }

    /// Kalıcı sekmeler ve seçili sekme bir sonraki açılışa taşınır; önizleme
    /// sekmesi geçici olduğu için taşınmaz.
    private func saveTabs() {
        let permanent = tabs.permanent.map(\.uuidString)
        UserDefaults.standard.set(permanent, forKey: Self.openTabsKey)
        let selected = selectedRequestID.flatMap { permanent.contains($0.uuidString) ? $0.uuidString : nil }
        UserDefaults.standard.set(selected, forKey: Self.selectedTabKey)
    }

    /// Silinmiş isteklerin sekmeleri atılır.
    private func pruneTabs() {
        let live = Set(workspace.collections.flatMap { $0.requests.map(\.id) })
        guard openTabs.contains(where: { !live.contains($0) }) else { return }
        selectedRequestID = tabs.prune(keeping: live, selected: selectedRequestID)
        saveTabs()
    }

    var saveError: String?

    // MARK: - Sidebar arama

    /// Sidebar filtresi. Kalıcı DEĞİL: arama geçici bir görünüm durumu,
    /// uygulamayı filtreli açmak "isteklerim kaybolmuş" etkisi yaratır.
    var searchQuery = ""

    /// Arama alanına odaklanma isteği (⌘F). Bool yerine sayaç: alan zaten
    /// odaklıyken ya da kullanıcı başka yere tıkladıktan sonra tekrar ⌘F'ye
    /// bastığında da gözlemlenebilir bir değişiklik olması gerekiyor.
    private(set) var searchFocusRequest = 0

    func focusSearch() {
        searchFocusRequest += 1
    }

    func clearSearch() {
        searchQuery = ""
    }

    // MARK: - Editör araması
    //
    // Gövde ve yanıt editörleri kendi aramalarını kendileri yönetir
    // (`EditorSearchController`); burada yalnızca menü komutunun onlara
    // ulaşması için sayaç tutuluyor. Sidebar aramasıyla aynı desen: sayaç,
    // çubuk zaten açıkken tekrar kısayola basmayı da gözlemlenebilir kılar.
    private(set) var bodySearchRequest = 0
    private(set) var responseSearchRequest = 0

    func openBodySearch() {
        bodySearchRequest += 1
    }

    func openResponseSearch() {
        responseSearchRequest += 1
    }

    /// Her satır için ayrı ayrı sorulduğundan ucuz tutuldu: `tokens(from:)`
    /// ile aynı sonucu verir (yalnızca boşluktan oluşan sorgu arama sayılmaz)
    /// ama dizi ayırmaz.
    var isSearching: Bool {
        searchQuery.contains { !$0.isWhitespace }
    }

    /// Sidebar'da gösterilecek koleksiyonlar; arama boşsa hepsi.
    var visibleCollections: [RequestSearch.Match] {
        RequestSearch.filter(workspace.collections, query: searchQuery)
    }

    /// Arama sonucundaki ilk istek — arama alanında ⏎ ile seçilir.
    var firstSearchHit: RequestModel? {
        visibleCollections.first(where: { !$0.requests.isEmpty })?.requests.first
    }

    /// İstek düzenleyicide açık sekme (⌘1…⌘4 ile de değişir).
    var editorTab: EditorTab = .headers

    /// Otomatik kaydın görünür hali. Görünmeyen kayıt, kaydetmemek kadar
    /// güvensizlik yaratıyor — kullanıcı ne olduğunu bilmeli.
    enum SaveState: Equatable {
        case idle
        case pending
        case saved(Date)
        case failed(String)
    }

    private(set) var saveState: SaveState = .idle

    /// Kapalı (collapse edilmiş) koleksiyonlar; UserDefaults'ta saklanır.
    var collapsedCollectionIDs: Set<UUID> = [] {
        didSet {
            UserDefaults.standard.set(
                collapsedCollectionIDs.map(\.uuidString),
                forKey: Self.collapsedKey
            )
        }
    }

    private static let collapsedKey = "collapsedCollections"

    func isCollectionCollapsed(_ id: UUID) -> Bool {
        collapsedCollectionIDs.contains(id)
    }

    func toggleCollectionCollapsed(_ id: UUID) {
        if collapsedCollectionIDs.contains(id) {
            collapsedCollectionIDs.remove(id)
        } else {
            collapsedCollectionIDs.insert(id)
        }
    }

    /// Sidebar'ın genişleyebileceği üst sınır: en uzun koleksiyon/istek adının
    /// gerçek piksel genişliği + nefes payı. Kullanıcı ayracı bundan öteye çekemez.
    ///
    /// Her render'da çağrıldığı için Core Text ölçümü yalnızca en uzun ADAYLARA
    /// uygulanır: önce ucuz karakter sayısıyla eleme yapılır, sonra tek tek ölçüm.
    /// (Tüm isimleri ölçmek yazarken gözle görülür takılmaya yol açıyordu.)
    var sidebarMaxWidth: CGFloat {
        var longestHeader = ""
        var longestRow = ""
        for collection in workspace.collections {
            if collection.name.count > longestHeader.count { longestHeader = collection.name }
            for request in collection.requests where request.name.count > longestRow.count {
                longestRow = request.name
            }
        }
        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let rowFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            text.isEmpty ? 0 : (text as NSString).size(withAttributes: [.font: font]).width
        }
        // başlık: chevron + tutamaç + padding ≈ 64px · satır: metot sütunu + boşluk ≈ 88px
        let widest = max(width(longestHeader, headerFont) + 64, width(longestRow, rowFont) + 88)
        return max(220, widest + 36)
    }

    /// Secret adları yazarken `{{` önerileri için sürekli isteniyor; her seferinde
    /// diskten okuyup AES-GCM çözmek tuş başına I/O demekti. Bellekte tutulur,
    /// secret değiştiğinde `invalidateSecretNames()` ile düşürülür.
    @ObservationIgnored private var cachedSecretNames: [String]?

    var secretNames: [String] {
        if let cachedSecretNames { return cachedSecretNames }
        let names = (try? secretStore.listSecretNames()) ?? []
        cachedSecretNames = names
        return names
    }

    func invalidateSecretNames() {
        cachedSecretNames = nil
    }

    var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceKey)
            Self.applyAppearance(appearanceMode)
        }
    }

    private static let appearanceKey = "appearanceMode"

    private static func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // Aşağıdaki üyeler `private` DEĞİL: AppState uzantı dosyalarından
    // (Sending, History, Porting) kullanılıyorlar. Uzantılar aynı modülde,
    // dolayısıyla dışarıya kapalılık modül sınırında korunuyor.
    let secretStore: SecretStore
    let store: WorkspaceStore
    /// Diske yazma MainActor'ı bloklamasın diye seri arka plan yazıcısı.
    private let saver: WorkspaceSaver
    let engine = RequestEngine()
    /// `private` değil: `AppState+History` uzantısı da kullanıyor.
    /// Uzantılar aynı modülde; dışarıya kapalılık modül sınırında korunuyor.
    let historyStore = HistoryStore()
    let approvalStore = SecurityApprovalStore()

    /// Yönetici politikası her kullanımda diskten okunur: yönetici dosyayı
    /// değiştirince uygulamayı yeniden başlatmak gerekmesin. Dosya küçük.
    var hostPolicy: HostPolicyState { HostPolicyLoader.load() }

    // MARK: - Geçmiş durumu (davranış: AppState+History)

    /// Geçmiş kayıtları, en yenisi başta.
    /// Yazan tek yer `AppState+History`; view'lar yalnızca okur.
    var history: [HistoryEntry] = []

    var historySettings: HistorySettings {
        didSet {
            if let data = try? JSONEncoder().encode(historySettings) {
                UserDefaults.standard.set(data, forKey: Self.historySettingsKey)
            }
        }
    }

    private static let historySettingsKey = "historySettings"

    /// Geçmiş dosyasının diskteki boyutu.
    var historyFileSize: Int { historyStore.fileSizeBytes() }

    func clearHistory(environmentName: String?) {
        historyStore.deleteEntries(environmentName: environmentName)
        reloadHistory()
    }

    enum ResponseState {
        case idle
        case loading
        case success(ResponseDisplay)
        case failure(String)
        /// Kesin güvenlik engeli; istek gönderilmedi.
        case blocked([SecurityFinding])
        /// Güvenlik uyarıları; istek gönderilmedi, kullanıcının kararı bekleniyor.
        case needsApproval([SecurityFinding])
    }

    /// Yanıtın gösterime hazır hali. Pretty-print ve dil tespiti yanıt gelince
    /// BİR KEZ, arka planda yapılır; her render'da yeniden JSON parse etmek
    /// büyük yanıtlarda paneli kilitliyordu.
    struct ResponseDisplay: Sendable {
        let data: ResponseData
        let prettyText: String
        let language: CodeLanguage
    }

    // FileSecretStore: imzasız dev binary'si Keychain'i her rebuild'de parola
    // sorduruyordu; imzalı dağıtımda KeychainSecretStore'a dönülebilir.
    init(store: WorkspaceStore = WorkspaceStore(), secretStore: SecretStore = FileSecretStore()) {
        self.store = store
        self.saver = WorkspaceSaver(store: store)
        self.secretStore = secretStore
        let collapsedStrings = UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []
        self.collapsedCollectionIDs = Set(collapsedStrings.compactMap(UUID.init(uuidString:)))
        let savedSettings = UserDefaults.standard.data(forKey: Self.historySettingsKey)
            .flatMap { try? JSONDecoder().decode(HistorySettings.self, from: $0) }
        self.historySettings = savedSettings ?? .default
        let savedMode = UserDefaults.standard.string(forKey: Self.appearanceKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        self.appearanceMode = savedMode
        Self.applyAppearance(savedMode)
        do {
            self.workspace = try store.load()
        } catch {
            // Bozuk dosyada veriyi ezmemek için boş workspace ile devam edip uyarı gösterilir.
            self.workspace = WorkspaceModel()
            self.saveError = "Workspace okunamadı: \(error.localizedDescription)"
        }
        if workspace.collections.isEmpty {
            workspace.collections = [CollectionModel(name: "İlk Koleksiyon", requests: [RequestModel()])]
            persist()
        }
        history = historyStore.entries()
        engine.tlsProfiles = workspace.tlsProfiles
        reloadTrustStore()

        let live = Set(workspace.collections.flatMap { $0.requests.map(\.id) })
        tabs = RequestTabs(tabs: (UserDefaults.standard.stringArray(forKey: Self.openTabsKey) ?? [])
            .compactMap(UUID.init(uuidString:))
            .filter(live.contains))
        let savedSelection = UserDefaults.standard.string(forKey: Self.selectedTabKey).flatMap(UUID.init(uuidString:))
        selectedRequestID = savedSelection.flatMap { openTabs.contains($0) ? $0 : nil } ?? openTabs.first
    }

    var activeEnvironment: EnvironmentModel? {
        workspace.environments.first { $0.id == workspace.activeEnvironmentID }
    }

    /// İsteğin güncel konumu. Index'ler binding içinde SAKLANMAZ: koleksiyon
    /// sürüklenince veya silinince eski index yanlış isteğe yazar ya da
    /// dizi sınırını aşıp çökertir. Her erişimde ID'den yeniden bulunur.
    func locateRequest(_ id: UUID) -> (collection: Int, request: Int)? {
        for (ci, collection) in workspace.collections.enumerated() {
            if let ri = collection.requests.firstIndex(where: { $0.id == id }) {
                return (ci, ri)
            }
        }
        return nil
    }

    /// İsteği yerinde değiştirir. "Bul → kopyala → yaz" dansı on bir yerde
    /// tekrarlanıyordu; index'i yalnızca burası biliyor.
    ///
    /// DİKKAT: `body` içinde `workspace`'e DOKUNMA. Bu çağrı `workspace` üzerinde
    /// yazma erişimi tutar; içeride ayrıca okumak "simultaneous access" hatası
    /// verip uygulamayı çökertir. İhtiyacın olan veriyi önce dışarıda oku.
    /// Salt okuma sorguları için `request(withID:)` kullan.
    ///
    /// - Returns: istek bulunduysa `body`'nin sonucu, yoksa `nil`.
    @discardableResult
    func withRequest<T>(_ id: UUID, _ body: (inout RequestModel) -> T) -> T? {
        guard let location = locateRequest(id) else { return nil }
        return body(&workspace.collections[location.collection].requests[location.request])
    }

    /// İsteğin bulunduğu koleksiyon.
    func collection(containing id: UUID) -> CollectionModel? {
        locateRequest(id).map { workspace.collections[$0.collection] }
    }

    var selectedRequest: Binding<RequestModel>? {
        guard let id = selectedRequestID, let location = locateRequest(id) else { return nil }
        let fallback = workspace.collections[location.collection].requests[location.request]
        return Binding(
            get: {
                guard let current = self.locateRequest(id) else { return fallback }
                return self.workspace.collections[current.collection].requests[current.request]
            },
            set: { newValue in
                guard let current = self.locateRequest(id) else { return }
                self.workspace.collections[current.collection].requests[current.request] = newValue
                // Düzenlenen istek artık "bakılan" değil "kullanılan" istektir.
                if self.previewTabID == id { self.pinTab(id) }
                // Metin düzenlemesi: her tuşta diske yazma, geciktir.
                self.persistSoon()
            }
        )
    }

    // MARK: - "Son gönderilenden farklı" takibi

    /// Son gönderildiği halden farklı isteklerin kimlikleri — TEK geçişte.
    ///
    /// Neden küme: `isDirty(_:)` satır başına çağrıldığında her satırda tüm
    /// koleksiyonları tarayıp (locateRequest) gövde metinlerini karşılaştırıyordu;
    /// 100+ istekte render başına O(n²) iş demekti ve listede takılma yaratıyordu.
    /// View bu kümeyi gövdesinde BİR kez okur, satırlar `contains` ile bakar.
    var dirtyRequestIDs: Set<UUID> {
        DirtyRequests.ids(in: workspace.collections, baselines: workspace.sentBaselines)
    }

    /// İstek en son gönderildiği halden farklı mı.
    /// Hiç gönderilmemiş isteklerde işaret çıkmaz: karşılaştırılacak bir
    /// "test edilmiş hal" yoktur.
    ///
    /// Tek istek için kullanılır (ör. açık isteğin başlığı). Liste/satır
    /// döngüsünde ÇAĞIRMA: orada `dirtyRequestIDs` kullanılır.
    func isDirty(_ id: UUID) -> Bool {
        // `withRequest` DEĞİL: o `workspace`'e yazma erişimi alır, içeride
        // `workspace.sentBaselines` okumak aynı anda erişim demek ve Swift
        // exclusivity kontrolü uygulamayı çökertir (canlı yakalandı).
        // Okuma sorgularında read-only erişimci kullanılır.
        guard let request = request(withID: id) else { return false }
        return DirtyRequests.isDirty(request, baselines: workspace.sentBaselines)
    }

    var lastSentBaseline: RequestModel? {
        guard let id = selectedRequestID else { return nil }
        return workspace.sentBaselines[id.uuidString]
    }

    /// İsteği en son gönderildiği hale döndürür. Ad ve kimlik korunur.
    /// Kaydedilmemiş düzenlemeleri geri alınamaz biçimde siler; çağıran
    /// taraf onay almalı.
    func revertToLastSent(_ id: UUID) {
        guard let baseline = workspace.sentBaselines[id.uuidString] else { return }
        let reverted = withRequest(id) { request in
            request = request.revertingFunctionalFields(to: baseline)
            return true
        }
        guard reverted == true else { return }
        pinTab(id)
        persist()
    }

    func recordBaseline(_ request: RequestModel) {
        workspace.sentBaselines[request.id.uuidString] = request
        workspace.pruneBaselines()
        persist()
    }

    func addRequest(to collectionID: UUID) {
        guard let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        let request = RequestModel()
        workspace.collections[index].requests.append(request)
        // Kapalı koleksiyona eklenen istek seçili ama görünmez kalırdı.
        collapsedCollectionIDs.remove(collectionID)
        selectedRequestID = request.id
        pinTab(request.id)
        persist()
    }

    /// ⌘N: yeni isteği en makul koleksiyona ekler — seçili isteğin koleksiyonu,
    /// yoksa ilk koleksiyon. Hiç koleksiyon yoksa bir tane açar; kısayol hiçbir
    /// durumda sessizce hiçbir şey yapmamalı.
    ///
    /// Açık arama temizlenir: yeni isteğin adı filtreye uymayacağı için aksi
    /// halde seçili ama listede görünmeyen bir istek oluşurdu.
    func addRequestToCurrentCollection() {
        clearSearch()
        if let id = selectedRequestID, let current = collection(containing: id) {
            addRequest(to: current.id)
            return
        }
        if let first = workspace.regularCollections.first {
            addRequest(to: first.id)
            return
        }
        let collection = CollectionModel()
        workspace.collections.append(collection)
        addRequest(to: collection.id)
    }

    /// İsteği aynı koleksiyonda hemen altına kopyalar ve seçer.
    /// Ad çakışmasında koleksiyon import'uyla aynı kural: "isim kopya", "isim kopya 2"…
    func duplicateRequest(_ id: UUID) {
        guard let location = locateRequest(id) else { return }
        var copy = workspace.collections[location.collection].requests[location.request]
        copy.id = UUID()
        copy.name = CollectionPorting.uniqueName(
            copy.name,
            suffix: "kopya",
            existingNames: workspace.collections[location.collection].requests.map(\.name)
        )
        workspace.collections[location.collection].requests.insert(copy, at: location.request + 1)
        selectedRequestID = copy.id
        pinTab(copy.id)
        persist()
    }

    /// İsteği başka bir koleksiyona taşır (hedefin sonuna eklenir).
    func moveRequest(_ id: UUID, toCollection targetID: UUID) {
        moveRequests([id], toCollection: targetID)
    }

    /// Seçili istekleri başka bir koleksiyona taşır; kaynak sıraları korunur.
    /// Ad çakışması tek istekteki kuralla aynı: "isim taşınan", "isim taşınan 2"…
    func moveRequests(_ ids: Set<UUID>, toCollection targetID: UUID) {
        guard !ids.isEmpty,
              let target = workspace.collections.firstIndex(where: { $0.id == targetID }) else { return }
        var moved: [RequestModel] = []
        for index in workspace.collections.indices where index != target {
            let picked = workspace.collections[index].requests.filter { ids.contains($0.id) }
            guard !picked.isEmpty else { continue }
            workspace.collections[index].requests.removeAll { ids.contains($0.id) }
            moved.append(contentsOf: picked)
        }
        guard !moved.isEmpty else { return }
        for var request in moved {
            let existing = workspace.collections[target].requests.map(\.name)
            request.name = CollectionPorting.uniqueName(request.name, suffix: "taşınan", existingNames: existing)
            workspace.collections[target].requests.append(request)
        }
        // Taşınanlar seçili kalsın: kullanıcı nereye gittiklerini görsün.
        selectedRequestIDs = Set(moved.map(\.id))
        selectedRequestID = moved.last?.id
        persist()
    }

    /// İsteği koleksiyonsuz bölüme taşır.
    func removeFromCollection(_ id: UUID) {
        removeFromCollection([id])
    }

    func removeFromCollection(_ ids: Set<UUID>) {
        moveRequests(ids, toCollection: workspace.ensureUngroupedCollection())
    }

    /// İçe aktarılan isteğin gideceği yer.
    enum CollectionDestination: Hashable {
        case ungrouped
        case existing(UUID)
        /// Aynı adda bir koleksiyon zaten varsa ona eklenir; kopyası açılmaz.
        case new(name: String)
    }

    /// Hedefi koleksiyon kimliğine çevirir; gerekiyorsa kabı ya da koleksiyonu oluşturur.
    func resolve(_ destination: CollectionDestination) -> UUID? {
        switch destination {
        case .ungrouped:
            return workspace.ensureUngroupedCollection()
        case .existing(let id):
            return workspace.collections.contains { $0.id == id } ? id : nil
        case .new(let rawName):
            let name = rawName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            if let existing = existingCollection(named: name) { return existing.id }
            let collection = CollectionModel(name: name)
            workspace.collections.append(collection)
            return collection.id
        }
    }

    // MARK: - İçe aktarma tipleri (davranış: AppState+Porting)

    struct OpenAPIFetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum KibanaImportTarget {
        case newRequest(CollectionDestination)
        case selectedRequest
    }

    func deleteRequest(_ id: UUID) {
        deleteRequests([id])
    }

    /// Seçili isteklerin tamamını siler. Tek yazım, tek geri bildirim.
    func deleteRequests(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in workspace.collections.indices {
            workspace.collections[index].requests.removeAll { ids.contains($0.id) }
        }
        ids.forEach { closeTab($0) }
        selectedRequestIDs.subtract(ids)
        if let id = selectedRequestID, ids.contains(id) { selectedRequestID = nil }
        persist()
    }

    func moveRequests(in collectionID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        workspace.collections[index].requests.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Yanıtlar istek KİMLİĞİNE göre tutulur: başka bir isteğe geçince eski
    /// yanıt orada kalır, yenisinin yanıtıymış gibi görünmez.
    /// Diske hiç yazılmaz — yanıt gövdeleri token/kişisel veri içerebilir.
    var responses: [UUID: ResponseState] = [:]
    /// Bellek sınırı: en son bu kadar yanıt saklanır, eskisi düşer.
    static let retainedResponseLimit = 15
    var responseOrder: [UUID] = []

    var lastResponse: ResponseState {
        guard let id = selectedRequestID else { return .idle }
        return responses[id] ?? .idle
    }

    var isSending: Bool {
        if case .loading = lastResponse { return true }
        return false
    }

    @ObservationIgnored var inFlight: [UUID: Task<Void, Never>] = [:]

    // MARK: - Token değişkenleri (davranış: AppState+Sending)

    enum TokenState: Equatable {
        case fetching
        case valid(expiresAt: Date?)
        case failed(String)
    }

    /// Arayüz için: environment + değişken başına son durum.
    var tokenStates: [String: TokenState] = [:]
    /// Token'lar yalnızca bellekte; uygulama kapanınca gider.
    @ObservationIgnored var tokenCache: [String: OAuth2Token] = [:]
    /// Süren alma işlemleri: aynı anda gelen istekler tek isteği paylaşır.
    @ObservationIgnored var tokenFetches: [String: Task<OAuth2Token, Error>] = [:]

    struct TokenError: LocalizedError {
        let variable: String
        let reason: String
        var errorDescription: String? { "{{\(variable)}} için token alınamadı; istek gönderilmedi. \(reason)" }
    }

    // MARK: - OAuth2 durumu (davranış: AppState+Sending)

    let oauthService = OAuth2Service()
    /// Yetkilendirme sürerken arayüzün beklemesi için.
    var authorizingConfigID: UUID?
    var authMessage: String?

    /// Token'ı vault'a yazar. Adı `store` DEĞİL: `store` aynı zamanda
    /// workspace deposunun adı, uzantı dosyalarında çağrı karışıyordu.
    func saveToken(_ token: OAuth2Token, for config: OAuth2Config) throws {
        let data = try JSONEncoder().encode(token)
        // Token vault'a yazılır; workspace dosyasına ASLA.
        try secretStore.setSecret(String(decoding: data, as: UTF8.self), forName: config.tokenSecretName)
        invalidateSecretNames()
    }

    func clearToken(for config: OAuth2Config) {
        try? secretStore.deleteSecret(forName: config.tokenSecretName)
        invalidateSecretNames()
        authMessage = "Token silindi."
    }

    // MARK: - TLS durumu (davranış: AppState+TLS)

    var trustStore: TrustStore.LoadResult = .init(entries: [], problems: [])

    var cookieScope: RequestEngine.Scope {
        RequestEngine.Scope(environmentID: workspace.activeEnvironmentID)
    }

    /// Ana thread dışında çalışır: büyük gövdeleri biçimlendirmek pahalıdır.
    nonisolated static func makeDisplay(_ response: ResponseData) -> ResponseDisplay {
        let contentType = response.headers
            .first { $0.name.lowercased() == "content-type" }?.value ?? ""
        let text = response.bodyText ?? "(ikili veri: \(response.body.count) byte)"
        // Tür tahmini ve biçimlendirme tek yerde: Beautifier (Core, testli).
        let kind = Beautifier.kind(contentType: contentType, body: text)
        return ResponseDisplay(
            data: response,
            prettyText: Beautifier.beautifiedOrOriginal(text, as: kind),
            language: CodeLanguage(kind)
        )
    }

    /// Import/export sonucunu (başarı, yeniden adlandırma, uyarılar) kullanıcıya
    /// gösteren alert metni.
    var portingMessage: String?

    enum ImportSource {
        case dev2kit
        case postman
    }

    /// İncelemeden geçmiş, onay bekleyen içe aktarma.
    struct PreparedImport: Identifiable {
        let review: CollectionReview
        let wasRenamed: Bool
        var id: UUID { review.id }
    }

    /// Kullanıcının kararını bekleyen dosya içe aktarması; kenar çubuğu
    /// inceleme ekranını bunun için açar.
    struct PendingImport: Identifiable {
        let id = UUID()
        let items: [PreparedImport]
    }

    var pendingImport: PendingImport?

    struct ImportFailure: Error {
        let message: String
    }

    var importContext: ImportReviewer.Context {
        ImportReviewer.Context(policy: hostPolicy, vaultSecretNames: Set(secretNames))
    }

    /// Öneri listesi için: aktif environment değişken adları + "secret:isim" girdileri.
    func templateSuggestions(matching token: String) -> [String] {
        TemplateSuggestions.options(
            environment: activeEnvironment,
            secretNames: secretNames,
            matching: token
        )
    }

    /// Yapısal değişiklikler (ekle/sil/sırala/içe aktar) için anında yazım.
    func persist() {
        pruneTabs()
        persistTask?.cancel()
        persistTask = nil
        writeWorkspace()
    }

    /// Metin düzenlemesi için geciktirilmiş yazım.
    ///
    /// Workspace TEK dosyaya pretty-printed JSON olarak, atomik (temp + rename)
    /// yazılıyor. Her tuş vuruşunda bunu yapmak tüm koleksiyonları yeniden
    /// encode edip main thread'de diske basmak demekti — yazarken takılmanın
    /// ana sebebi buydu. Yazım durduktan 400ms sonra tek sefer yazılır.
    func persistSoon() {
        saveState = .pending
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.writeWorkspace()
        }
    }

    /// Bekleyen yazımı hemen tamamlar (istek gönderme, pencere kapanışı gibi
    /// veri kaybı riski olan anlarda çağrılır).
    func flushPendingWrites() {
        guard persistTask != nil else { return }
        persist()
    }

    @ObservationIgnored private var persistTask: Task<Void, Never>?

    private func writeWorkspace() {
        persistTask = nil
        // Encode + disk yazımı arka planda; MainActor yalnızca sonucu işler.
        saver.save(workspace) { error in
            MainActor.assumeIsolated {
                guard let error else {
                    self.saveError = nil
                    self.saveState = .saved(Date())
                    return
                }
                self.saveError = "Kaydedilemedi: \(error.localizedDescription)"
                self.saveState = .failed(error.localizedDescription)
            }
        }
    }

    /// Bekleyen yazımı başlatıp bitmesini bekler.
    /// Yalnızca uygulama kapanışında çağrılır: kapanırken yarım kalan yazım
    /// veri kaybı demektir. Normal akışta `flushPendingWrites()` yeterlidir.
    func waitForPendingWrites() {
        flushPendingWrites()
        saver.waitForPendingWrites()
    }
}
