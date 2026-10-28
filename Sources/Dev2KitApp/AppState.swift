import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Dev2KitCore

// AppState tek sınıf, birden çok dosyaya yayılmış. Burada yalnızca DURUM
// (saklanan özellikler — Swift bunları uzantıya taşımaya izin vermiyor) ve
// `init` var; davranış uzantı dosyalarında:
//
//   AppState+Requests      istek bulma, ekleme/çoğaltma/taşıma/silme, "son gönderilenden farklı"
//   AppState+Tabs          açık sekmeler, `showRequest`, sekmelerin kaydı ve geri yüklenmesi
//   AppState+Sidebar       arama sonucu, daraltılmış koleksiyonlar, kenar çubuğu genişliği
//   AppState+Persistence   workspace'in diske yazılması (`persist`, `persistSoon`)
//   AppState+Sending       gönderim, yanıt, güvenlik onayı, OAuth2
//   AppState+TokenFactory  token üreten istekler ve token'ların bellekteki yaşamı
//   AppState+Porting       içe/dışa aktarma (dosya, Postman, cURL, Kibana, OpenAPI, kaynak tarama)
//   AppState+History       geçmiş kaydı ve geçmişten geri yükleme
//   AppState+Collections   koleksiyon ve environment yönetimi
//   AppState+TLS           güven deposu, TLS profilleri, çerezler
//   AppState+Examples      response örnekleri: kaydet, aç, "Dene", yeniden adlandır, sil
//
// Uzantılardan yazılan özellikler `private(set)` DEĞİL; uzantılar aynı
// modülde, dışarıya kapalılık modül sınırında korunuyor.
//
// Saf kurallar burada DEĞİL, `Dev2KitCore`'da ve testli: seçim (MultiSelection),
// kirlilik (DirtyRequests), geçmişten geri yükleme (HistoryRestore), öneriler
// (TemplateSuggestions), sekme kuralları (RequestTabs), arama (RequestSearch),
// token önbelleği (TokenCacheKey).

/// Uygulamanın tek merkezi durumu. Bu dosyada yalnızca DURUM (saklanan
/// özellikler) ve `init` var; davranış uzantı dosyalarında (bkz. üstteki harita).
@Observable
@MainActor
final class AppState {
    var workspace: WorkspaceModel

    /// Açık mod. Bir sonraki açılışta hatırlanır. Workbench'teyken API Client
    /// kısayolları devre dışıdır (menü komutları buna bakar); mod değişince
    /// API Client'ın durumu (sekmeler, gövde, yanıtlar) burada kaldığı için
    /// kaybolmaz.
    var mode: AppMode = AppMode(rawValue: UserDefaults.standard.string(forKey: "appMode") ?? "") ?? .apiClient {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appMode") }
    }

    var isAPIClient: Bool { mode == .apiClient }
    /// Seçili istek. Açık değilse önizleme sekmesinde açılır (bkz. Sekmeler).
    var selectedRequestID: UUID? {
        didSet {
            // Açık örnek yalnızca kendi isteği seçiliyken yaşar: başka isteğe,
            // sekmeye geçmek ya da isteği kapatmak örnek görünümünü kapatır.
            if let example = openExample, example.requestID != selectedRequestID { openExample = nil }
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
    /// Setter modül içi: taşıma/silme (`AppState+Requests`) kümeyi günceller.
    var selectedRequestIDs: Set<UUID> = []

    /// Listeden gelen yeni seçim kümesini uygular.
    /// `order`: görünen isteklerin sırası — aktif istek buna göre belirlenir.
    func applySelection(_ ids: Set<UUID>, order: [UUID]) {
        let active = MultiSelection.active(current: selectedRequestID, selection: ids, order: order)
        // Listede istek seçmek (açık örneğin isteği dahil) istek editörüne döner.
        openExample = nil
        selectedRequestIDs = ids
        selectedRequestID = active
    }

    // MARK: - Response örnekleri (davranış: AppState+Examples)

    /// Görüntülenen kayıtlı örnek. Açıkken istek editörü yerine örnek
    /// görünümü çizilir ve HİÇBİR gönderim yolu ağa çıkmaz (`send` başta
    /// bakar). Diske yazılmaz: açılış her zaman istekle başlar.
    var openExample: ExampleRef?
    /// "Örnek olarak kaydet" sürüyor: alınmış anlık görüntü ve aşama.
    /// Sınır doluyken örnek silinip kaydetmeye dönülse de görüntü aynıdır.
    var pendingExampleSave: PendingExampleSave?
    /// Yeniden adlandırma / silme onayı bekleyen örnek (kenar çubuğu ve örnek
    /// görünümü aynı kutuyu kullanır; kutu `APIClientLayout`'ta).
    var exampleRenameTarget: ExampleRef?
    var exampleDeleteTarget: ExampleRef?

    // MARK: - Sekmeler (davranış: AppState+Tabs)

    /// Açık istek sekmeleri; kurallar `RequestTabs`'ta (Core, testli).
    /// Setter modül içi: `AppState+Tabs` yazıyor.
    var tabs = RequestTabs()
    var openTabs: [UUID] { tabs.tabs }
    var previewTabID: UUID? { tabs.preview }

    var saveError: String?
    /// Açılışta workspace okunamadı mesajı. `saveError`'dan ayrı: başarılı
    /// ilk kayıt `saveError`'ı temizliyor, uyarı kullanıcı görmeden siliniyordu.
    /// Yalnızca kullanıcı kapatınca gider. Yedek alındıysa uyarı, alınamadıysa
    /// (kayıt kapalı) hata.
    var startupMessage: ResultMessage?

    // MARK: - Sidebar arama

    /// Araç çubuğundaki logonun penceredeki sağ kenarı (point; ölçülene
    /// kadar `nil`). Sol panelin asgari genişliği buna göre (`SidebarSizing`).
    var headerLogoTrailingEdge: CGFloat?

    var sidebarMinimumWidth: CGFloat {
        SidebarSizing.minimumWidth(logoTrailingEdge: headerLogoTrailingEdge, logoWidth: HeaderLogo.size.width)
    }

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

    // MARK: - Sertifika doğrulama anahtarı

    /// Sunucu sertifikası doğrulaması uygulama genelinde kapalı mı.
    ///
    /// DİSKE YAZILMAZ: her açılışta kapalı başlar. Açık unutulan anahtar
    /// ertesi gün tüm istekleri sessizce korumasız göndermesin.
    // TODO(showcase): geçici kaçış kapısı. İleride host bazlı hale getirilecek
    // ya da tamamen kaldırılacak — bkz. TODO.md "Sertifika doğrulama anahtarı".
    var certificateValidationDisabled = false {
        didSet { engine.skipCertificateValidation = certificateValidationDisabled }
    }

    // MARK: - TLS profil önerisi
    //
    // Uzantılardan (`AppState+TLS`) yazıldığı için `private(set)` değil.

    /// TLS güven hatasından sonra çıkan "şu profile eklensin mi" önerisi.
    var tlsSuggestion: TLSPatternSuggestion.Match?

    /// Bu oturumda reddedilen host'lar. DİSKE YAZILMAZ: "hayır" kararını
    /// kalıcı saklamak, kullanıcı aylar sonra gerçekten eklemek istediğinde
    /// ona bir daha teklif edilmemesi demek olurdu. Oturum içi susturma
    /// dırdırı keser, kalıcı olumsuz kayıt tutmaz.
    var declinedTLSSuggestionHosts: Set<String> = []

    /// TLS ayarları penceresini açma isteği. Sidebar aramasındaki desenle aynı.
    private(set) var tlsSettingsRequest = 0
    /// Kenar çubuğunda görünür yapılacak istek (yeni oluşturulan); liste
    /// kaydırıp bir kez okur.
    var sidebarRevealID: UUID?
    /// Açılan isteğin adres alanı odak alsın (boş durumdan yeni istek).
    /// Adres alanı bir kez okur.
    var addressFocusPending = false

    /// Environment'lar penceresini açma isteği (tanımsız değişkene tıklama).
    var environmentsRequest = 0
    /// Pencere açılınca değeri verilecek değişken; bir kez okunur.
    var variableDefinitionRequest: VariableDefinitionRequest?

    /// Environment'lar penceresi açılınca seçilecek environment (seçicideki
    /// "değerleri düzenle" düğmesi). Pencere açılırken bir kez okunur.
    private(set) var environmentsFocusID: UUID?

    /// Environment'lar penceresini verilen environment seçili açar.
    func showEnvironments(focus id: UUID?) {
        environmentsFocusID = id
        environmentsRequest += 1
    }

    /// Seçilecek environment; yoksa ya da silinmişse `nil`.
    func takeEnvironmentsFocusID() -> UUID? {
        defer { environmentsFocusID = nil }
        guard let id = environmentsFocusID, workspace.environments.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Pencere açılınca seçilecek profil (TLS öneri kutusundaki "Profili Aç").
    /// Pencere açılırken bir kez okunur ve temizlenir.
    private(set) var tlsSettingsProfileID: UUID?

    func showTLSSettings(profileID: UUID? = nil) {
        tlsSettingsProfileID = profileID
        tlsSettingsRequest += 1
    }

    /// Açılışta seçilecek profil; yoksa ya da profil silinmişse `nil`.
    func takeTLSSettingsProfileID() -> UUID? {
        defer { tlsSettingsProfileID = nil }
        guard let id = tlsSettingsProfileID,
              workspace.tlsProfiles.contains(where: { $0.id == id }) else { return nil }
        return id
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

    /// API Client'ın kod editörleri; editör kimliği olarak metin görünümüne
    /// yazılır (`CodeEditor.paneIdentifier`), ⌘F klavye odağından okur.
    enum CodeEditorPane: String {
        case body = "dev2kit.editor.body"
        case response = "dev2kit.editor.response"
    }

    /// ⌘F API Client'ta: klavye odağı gövde ya da yanıt editöründeyse orada,
    /// değilse istek listesinde arar (kullanıcı isteği, 2026-10-20: yanıta
    /// tıklayıp ⌘F). Tahmin yok: odaktaki görünümün kimliğine bakılır; bir
    /// metin alanı (başlık hücresi, arama kutusu) editör sayılmaz.
    func findInAPIClient(firstResponder: NSResponder?) {
        let identifier = (firstResponder as? NSTextView)?.identifier?.rawValue
        switch identifier.flatMap(CodeEditorPane.init(rawValue:)) {
        case .body: openBodySearch()
        case .response: openResponseSearch()
        case nil: focusSearch()
        }
    }

    /// İstek düzenleyicide açık sekme (⌘1…⌘4 ile de değişir).
    var editorTab: EditorTab = .headers

    /// Setter modül içi: `AppState+Persistence` yazıyor.
    var saveState: SaveState = .idle

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

    /// Örnekleri açık istekler; diğerlerinin örnekleri katlı (varsayılan,
    /// kullanıcı kararı 2026-10-28). UserDefaults'ta saklanır.
    var expandedExampleRequestIDs: Set<UUID> = [] {
        didSet {
            UserDefaults.standard.set(
                expandedExampleRequestIDs.map(\.uuidString),
                forKey: Self.expandedExamplesKey
            )
        }
    }

    static let expandedExamplesKey = "expandedExampleRequests"

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
            appearanceMode.apply()
        }
    }

    private static let appearanceKey = "appearanceMode"

    /// Zinciri güven deposundaki bir CA'ya çıkan sertifikalarda ömür üst
    /// sınırı aranmasın mı. Doğrulama anahtarının aksine KALICI: bu bir
    /// gevşetme değil, kurum PKI'sına dair bilinçli bir yapılandırma; host
    /// profilindeki aynı seçenek de diske yazılıyor.
    var trustStoreAllowsLongValidity: Bool {
        didSet {
            UserDefaults.standard.set(trustStoreAllowsLongValidity, forKey: Self.trustStoreLongValidityKey)
            engine.trustStoreAllowsLongValidity = trustStoreAllowsLongValidity
        }
    }
    private static let trustStoreLongValidityKey = "trustStoreAllowsLongValidity"

    // Aşağıdaki üyeler `private` DEĞİL: AppState uzantı dosyalarından
    // (Sending, History, Porting) kullanılıyorlar. Uzantılar aynı modülde,
    // dolayısıyla dışarıya kapalılık modül sınırında korunuyor.
    let secretStore: SecretStore
    let store: WorkspaceStore
    /// Diske yazma MainActor'ı bloklamasın diye seri arka plan yazıcısı.
    let saver: WorkspaceSaver
    let engine = RequestEngine()
    /// `private` değil: `AppState+History` uzantısı da kullanıyor.
    /// Uzantılar aynı modülde; dışarıya kapalılık modül sınırında korunuyor.
    /// Anahtarın yeri imzaya göre seçilir (bkz. `defaultHistoryStore`).
    let historyStore: HistoryStore
    let approvalStore = SecurityApprovalStore()

    /// Yönetici politikası her kullanımda diskten okunur: yönetici dosyayı
    /// değiştirince uygulamayı yeniden başlatmak gerekmesin. Dosya küçük.
    var hostPolicy: HostPolicyState { hostPolicyForTesting ?? HostPolicyLoader.load() }

    /// YALNIZCA testler: makinedeki gerçek `/Library/.../policy.json`'dan
    /// bağımsız çalışsınlar (`AppStateHarness`). Ortam değişkeni ya da dosya
    /// ile ayarlanamaz; politikayı atlatmanın bir yolu değildir.
    @ObservationIgnored var hostPolicyForTesting: HostPolicyState?

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

    /// `secretStore` verilmezse Keychain (bkz. `defaultSecretStore`). Testler
    /// her zaman kendi deposunu verir: kullanıcının Keychain'ine dokunulmaz.
    init(store: WorkspaceStore = WorkspaceStore(), secretStore: SecretStore? = nil) {
        self.store = store
        self.saver = WorkspaceSaver(store: store, queue: PersistenceQueue.shared)
        let secrets = secretStore.map { ($0, nil as ResultMessage?, nil as String?) } ?? Self.defaultSecretStore()
        self.secretStore = secrets.0
        let historyStore = Self.defaultHistoryStore()
        self.historyStore = historyStore.0
        let collapsedStrings = UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []
        self.collapsedCollectionIDs = Set(collapsedStrings.compactMap(UUID.init(uuidString:)))
        let savedSettings = UserDefaults.standard.data(forKey: Self.historySettingsKey)
            .flatMap { try? JSONDecoder().decode(HistorySettings.self, from: $0) }
        self.historySettings = savedSettings ?? .default
        let savedMode = UserDefaults.standard.string(forKey: Self.appearanceKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        self.appearanceMode = savedMode
        savedMode.apply()
        self.trustStoreAllowsLongValidity = UserDefaults.standard.bool(forKey: Self.trustStoreLongValidityKey)
        do {
            let opened = try store.open()
            self.workspace = opened.workspace
            self.startupMessage = Self.startupMessage(for: opened.notices)
            opened.notices.forEach { DiagnosticLog.shared.record(DiagnosticEvent(kind: .storageRecovered, detail: $0.diagnosticDetail)) }
        } catch {
            DiagnosticLog.shared.record(DiagnosticEvent(kind: .storageOpenFailed, error: error))
            // Daha yeni şema, tamamlanamayan işlem ya da doğrulanamayan geçiş:
            // diskteki veri ezilmesin diye bu oturumda hiç yazılmaz.
            self.workspace = WorkspaceModel()
            self.persistenceBlocked = true
            self.startupMessage = ResultMessage(
                kind: .error,
                title: L10n.t("startup.blocked.title"),
                message: error.localizedDescription,
                revealURL: store.layout.root
            )
        }
        if let failure = secrets.1 {
            startupMessage = startupMessage ?? failure
            DiagnosticLog.shared.record(DiagnosticEvent(kind: .secretStoreUnavailable))
        }
        if let migrated = secrets.2 { startupMessage = Self.adding(MessageLine(.info, migrated), to: startupMessage) }
        if let failure = historyStore.1 {
            startupMessage = startupMessage ?? failure
            DiagnosticLog.shared.record(DiagnosticEvent(kind: .historyKeyUnavailable))
        }
        if workspace.collections.isEmpty {
            workspace.collections = [CollectionModel(name: L10n.t("collection.first"), requests: [RequestModel(name: L10n.t("request.newName"))])]
            persist()
        }
        // Silinmiş isteklerin kimlikleri birikmesin: yalnızca var olanlar.
        let savedExpanded = UserDefaults.standard.stringArray(forKey: Self.expandedExamplesKey) ?? []
        let requestIDs = Set(workspace.collections.flatMap { $0.requests.map(\.id) })
        self.expandedExampleRequestIDs = Set(savedExpanded.compactMap(UUID.init(uuidString:))).intersection(requestIDs)
        // Eski environment "token değişkenleri" Token Factory'ye taşınır; bir
        // kez çalışır (taşınanlar environment'tan silinir).
        if TokenFactoryMigration.migrate(&workspace) > 0 {
            persist()
        }
        history = self.historyStore.entries()
        if let failure = self.historyStore.keyFailure {
            startupMessage = startupMessage ?? ResultMessage(
                kind: .warning,
                title: L10n.t("history.keyUnavailable.title"),
                message: L10n.t("history.keyUnavailable.message", failure.localizedDescription)
            )
            DiagnosticLog.shared.record(DiagnosticEvent(kind: .historyKeyUnavailable, error: failure))
        }
        engine.tlsProfiles = workspace.tlsProfiles
        engine.trustStoreAllowsLongValidity = trustStoreAllowsLongValidity
        reloadTrustStore()

        restoreTabs()
    }

    var activeEnvironment: EnvironmentModel? {
        workspace.environments.first { $0.id == workspace.activeEnvironmentID }
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

    // MARK: - Token Factory (davranış: AppState+TokenFactory)

    /// Arayüz için: environment + kaynak başına son durum.
    var tokenStates: [TokenCacheKey: TokenState] = [:]
    /// Token'lar yalnızca bellekte; uygulama kapanınca gider. Diske, vault'a
    /// bile yazılmaz.
    @ObservationIgnored var tokenCache: [TokenCacheKey: TokenFactory.IssuedToken] = [:]
    /// Süren alma işlemleri: aynı anda gelen istekler tek isteği paylaşır.
    @ObservationIgnored var tokenFetches: [TokenCacheKey: Task<TokenFactory.IssuedToken, Error>] = [:]

    var tokenAlert: TokenAlert?

    /// Token kullanan istek hata aldıysa yanıtın üstünde gösterilecek öneri
    /// (bkz. `TokenRetryAdvice`). İstek başına; yeni gönderimde sıfırlanır.
    var tokenRetryAdvice: [UUID: TokenRetryAdvice] = [:]

    /// Token alınamadığı için GÖNDERİLMEYEN istekler ve kullandıkları
    /// değişkenler. "Yine de gönder (token olmadan)" düğmesi buna bakar.
    var tokenBlockedSends: [UUID: [String]] = [:]

    // MARK: - OAuth2 durumu (davranış: AppState+Sending)

    let oauthService = OAuth2Service()
    /// Yetkilendirme sürerken arayüzün beklemesi için.
    var authorizingConfigID: UUID?
    /// OAuth2 durum mesajı. Başarı ayrı bayrakla: renk metne bakılarak
    /// seçiliyordu ("tamamlandı" içeriyor mu), dil değişince bozulurdu.
    var authMessage: (text: String, isSuccess: Bool)?

    // MARK: - TLS durumu (davranış: AppState+TLS)

    var trustStore: TrustStore.LoadResult = .init(entries: [], problems: [])

    var cookieScope: RequestEngine.Scope {
        RequestEngine.Scope(environmentID: workspace.activeEnvironmentID)
    }

    /// Import/export sonucu. Hata türü sistem alert'inde, diğerleri sonuç
    /// penceresinde gösterilir (`ContentView`).
    var portingMessage: ResultMessage?

    /// Sıradaki gösterilecek mesaj. Öncelik: açılış, kayıt hatası, aktarım;
    /// açılış mesajı ilk kayıt hatasının altında kaybolmasın.
    var presentedMessage: ResultMessage? {
        if let startupMessage { return startupMessage }
        if let saveError {
            return ResultMessage(
                kind: .error,
                title: L10n.t("save.failed.title"),
                message: L10n.t("save.failed.message", saveError)
            )
        }
        return portingMessage
    }

    /// Yalnızca hâlâ gösterilen mesajsa kapatır: pencere kapanırken gelen
    /// ikinci bildirim sıradaki mesajı silmesin.
    func dismissMessage(_ id: UUID) {
        if startupMessage?.id == id {
            startupMessage = nil
        } else if portingMessage?.id == id {
            portingMessage = nil
        }
    }

    func dismissPresentedMessage() {
        if startupMessage != nil {
            startupMessage = nil
        } else if saveError != nil {
            saveError = nil
        } else {
            portingMessage = nil
        }
    }

    var pendingImport: PendingImport?

    /// Öneri listesi için: aktif environment değişken adları + "secret:isim" girdileri.
    /// Alandaki `{{ad}}`'a tıklanınca baloncukta gösterilecek bilgi.
    func variablePreview(for name: String) -> TemplateVariables.Preview {
        TemplateVariables.preview(
            for: name,
            environment: activeEnvironment,
            tokenVariables: tokenSources(for: activeEnvironment).map { ($0.variable, $0.request.name) },
            secretNames: secretNames
        )
    }

    func templateSuggestions(matching token: String) -> [String] {
        TemplateSuggestions.options(
            environment: activeEnvironment,
            secretNames: secretNames,
            tokenVariables: tokenSources(for: activeEnvironment).map(\.variable),
            matching: token
        )
    }

    /// Bekleyen gecikmeli yazım (`persistSoon`); `AppState+Persistence` yönetir.
    @ObservationIgnored var persistTask: Task<Void, Never>?
    /// Okunamayan workspace dosyası yedeklenemedi: üzerine yazılmasın diye bu
    /// oturumda kayıt yapılmaz (bkz. `init`).
    @ObservationIgnored private(set) var persistenceBlocked = false


}
