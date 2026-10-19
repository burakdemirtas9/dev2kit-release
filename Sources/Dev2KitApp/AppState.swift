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
        selectedRequestIDs = ids
        selectedRequestID = active
    }

    // MARK: - Sekmeler (davranış: AppState+Tabs)

    /// Açık istek sekmeleri; kurallar `RequestTabs`'ta (Core, testli).
    /// Setter modül içi: `AppState+Tabs` yazıyor.
    var tabs = RequestTabs()
    var openTabs: [UUID] { tabs.tabs }
    var previewTabID: UUID? { tabs.preview }

    var saveError: String?
    /// Açılışta workspace okunamadı uyarısı. `saveError`'dan ayrı: başarılı
    /// ilk kayıt `saveError`'ı temizliyor, uyarı kullanıcı görmeden siliniyordu.
    /// Yalnızca kullanıcı kapatınca gider.
    var startupWarning: String?

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

    func showTLSSettings() {
        tlsSettingsRequest += 1
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
        savedMode.apply()
        self.trustStoreAllowsLongValidity = UserDefaults.standard.bool(forKey: Self.trustStoreLongValidityKey)
        do {
            self.workspace = try store.load()
        } catch {
            // Boş workspace ile devam edilir; aşağıdaki ilk kayıt dosyanın
            // üzerine yazacağı için bozuk dosya ÖNCE yedeklenir. Yedek
            // alınamazsa bu oturumda hiç yazılmaz: veri ezilmektense
            // değişiklikler kaydedilmesin.
            self.workspace = WorkspaceModel()
            do {
                let backup = try store.backUpUnreadableFile()
                self.startupWarning = "Workspace okunamadı: \(error.localizedDescription)\n\n"
                    + "Okunamayan dosya yedeklendi:\n\(backup.path)\n\nBoş bir workspace ile açıldı."
            } catch let backupError {
                self.persistenceBlocked = true
                self.startupWarning = "Workspace okunamadı: \(error.localizedDescription)\n\n"
                    + "Dosya yedeklenemedi (\(backupError.localizedDescription)). Üzerine yazılmaması için "
                    + "bu oturumda değişiklikler KAYDEDİLMEYECEK. Dosyayı düzeltip ya da kenara alıp "
                    + "uygulamayı yeniden aç:\n\(store.fileURL.path)"
            }
        }
        if workspace.collections.isEmpty {
            workspace.collections = [CollectionModel(name: "İlk Koleksiyon", requests: [RequestModel()])]
            persist()
        }
        // Eski environment "token değişkenleri" Token Factory'ye taşınır; bir
        // kez çalışır (taşınanlar environment'tan silinir).
        if TokenFactoryMigration.migrate(&workspace) > 0 {
            persist()
        }
        history = historyStore.entries()
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
    var authMessage: String?

    // MARK: - TLS durumu (davranış: AppState+TLS)

    var trustStore: TrustStore.LoadResult = .init(entries: [], problems: [])

    var cookieScope: RequestEngine.Scope {
        RequestEngine.Scope(environmentID: workspace.activeEnvironmentID)
    }

    /// Import/export sonucunu (başarı, yeniden adlandırma, uyarılar) kullanıcıya
    /// gösteren alert metni.
    var portingMessage: String?

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
