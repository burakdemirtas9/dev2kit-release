import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import SecoraCore

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
    var selectedRequestID: UUID?

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

    let secretStore: SecretStore
    private let store: WorkspaceStore
    private let engine = RequestEngine()
    private let historyStore = HistoryStore()

    // MARK: - Geçmiş

    /// Geçmiş kayıtları, en yenisi başta.
    private(set) var history: [HistoryEntry] = []

    var historySettings: HistorySettings {
        didSet {
            if let data = try? JSONEncoder().encode(historySettings) {
                UserDefaults.standard.set(data, forKey: Self.historySettingsKey)
            }
        }
    }

    private static let historySettingsKey = "historySettings"

    func reloadHistory() {
        history = historyStore.entries()
    }

    /// Geçmiş dosyasının diskteki boyutu.
    var historyFileSize: Int { historyStore.fileSizeBytes() }

    func clearHistory() {
        historyStore.deleteAll()
        reloadHistory()
    }

    func clearHistory(environmentName: String?) {
        historyStore.deleteEntries(environmentName: environmentName)
        reloadHistory()
    }

    func deleteHistoryEntry(_ id: UUID) {
        historyStore.delete(id: id)
        reloadHistory()
    }

    /// Geçmişteki hali mevcut isteğe geri yazar.
    /// Maskelenmiş alanlar geri yüklenmez: "••••••" değerini isteğe yazmak
    /// çalışan bir kimlik bilgisini sessizce bozardı.
    func restore(_ entry: HistoryEntry) -> Bool {
        guard let requestID = entry.requestID, let location = locateRequest(requestID) else { return false }
        var target = workspace.collections[location.collection].requests[location.request]
        let snapshot = entry.snapshot
        target.method = snapshot.method
        target.url = snapshot.url.contains(HistoryRedactor.mask) ? target.url : snapshot.url
        target.queryParams = merge(snapshot.queryParams, into: target.queryParams)
        target.headers = merge(snapshot.headers, into: target.headers)
        target.body = snapshot.body
        target.options = snapshot.options
        if !containsMask(snapshot.auth) { target.auth = snapshot.auth }
        workspace.collections[location.collection].requests[location.request] = target
        selectedRequestID = target.id
        persist()
        return true
    }

    /// Geçmişteki isteği yeni bir istek olarak ekler (silinmiş isteği kurtarmak için).
    func restoreAsNewRequest(_ entry: HistoryEntry, to collectionID: UUID) {
        var snapshot = entry.snapshot
        snapshot.name = entry.requestName
        addImportedRequest(snapshot, to: collectionID)
    }

    /// Maskeli değerler eski hâliyle korunur; diğerleri anlık görüntüden gelir.
    private func merge(_ snapshot: [KeyValueEntry], into current: [KeyValueEntry]) -> [KeyValueEntry] {
        snapshot.map { entry in
            guard entry.value.contains(HistoryRedactor.mask) else { return entry }
            var restored = entry
            restored.value = current.first { $0.key.lowercased() == entry.key.lowercased() }?.value ?? ""
            return restored
        }
    }

    private func containsMask(_ auth: AuthConfig) -> Bool {
        switch auth {
        case .none: return false
        case .basic(_, let password): return password.contains(HistoryRedactor.mask)
        case .bearer(let token): return token.contains(HistoryRedactor.mask)
        case .apiKey(_, let value, _): return value.contains(HistoryRedactor.mask)
        case .oauth2(let config): return config.clientSecret.contains(HistoryRedactor.mask)
        }
    }

    /// Gönderim sonucunu geçmişe yazar. Anlık görüntü ŞABLON halidir ve
    /// ham kimlik bilgileri maskelenir.
    private func recordHistory(_ request: RequestModel, outcome: HistoryEntry.Outcome, responseText: String?) {
        guard historySettings.isEnabled else { return }
        let collectionName = workspace.collections.first { collection in
            collection.requests.contains { $0.id == request.id }
        }?.name
        let preview = historySettings.storeResponseBodies
            ? responseText.map { HistoryRedactor.redactResponse($0, limit: historySettings.responsePreviewLimit) }
            : nil
        let entry = HistoryEntry(
            requestID: request.id,
            requestName: request.name,
            collectionName: collectionName,
            environmentName: activeEnvironment?.name,
            method: request.method,
            url: HistoryRedactor.maskURL(request.url),
            outcome: outcome,
            snapshot: HistoryTrimmer.trim(
                HistoryRedactor.redact(request),
                maxBodyBytes: historySettings.maxSnapshotBodyBytes
            ),
            responsePreview: preview
        )
        history = historyStore.append(entry, settings: historySettings)
    }

    enum ResponseState {
        case idle
        case loading
        case success(ResponseDisplay)
        case failure(String)
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
    }

    var activeEnvironment: EnvironmentModel? {
        workspace.environments.first { $0.id == workspace.activeEnvironmentID }
    }

    /// İsteğin güncel konumu. Index'ler binding içinde SAKLANMAZ: koleksiyon
    /// sürüklenince veya silinince eski index yanlış isteğe yazar ya da
    /// dizi sınırını aşıp çökertir. Her erişimde ID'den yeniden bulunur.
    private func locateRequest(_ id: UUID) -> (collection: Int, request: Int)? {
        for (ci, collection) in workspace.collections.enumerated() {
            if let ri = collection.requests.firstIndex(where: { $0.id == id }) {
                return (ci, ri)
            }
        }
        return nil
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
                // Metin düzenlemesi: her tuşta diske yazma, geciktir.
                self.persistSoon()
            }
        )
    }

    // MARK: - "Son gönderilenden farklı" takibi

    /// İstek en son gönderildiği halden farklı mı.
    /// Hiç gönderilmemiş isteklerde işaret çıkmaz: karşılaştırılacak bir
    /// "test edilmiş hal" yoktur.
    func isDirty(_ id: UUID) -> Bool {
        guard let baseline = workspace.sentBaselines[id.uuidString],
              let location = locateRequest(id) else { return false }
        return !workspace.collections[location.collection].requests[location.request]
            .isFunctionallyEqual(to: baseline)
    }

    func hasDirtyRequest(in collection: CollectionModel) -> Bool {
        collection.requests.contains { isDirty($0.id) }
    }

    var lastSentBaseline: RequestModel? {
        guard let id = selectedRequestID else { return nil }
        return workspace.sentBaselines[id.uuidString]
    }

    /// İsteği en son gönderildiği hale döndürür. Ad ve kimlik korunur.
    /// Kaydedilmemiş düzenlemeleri geri alınamaz biçimde siler; çağıran
    /// taraf onay almalı.
    func revertToLastSent(_ id: UUID) {
        guard let baseline = workspace.sentBaselines[id.uuidString],
              let location = locateRequest(id) else { return }
        var target = workspace.collections[location.collection].requests[location.request]
        target.method = baseline.method
        target.url = baseline.url
        target.headers = baseline.headers
        target.queryParams = baseline.queryParams
        target.body = baseline.body
        target.auth = baseline.auth
        target.options = baseline.options
        workspace.collections[location.collection].requests[location.request] = target
        persist()
    }

    private func recordBaseline(_ request: RequestModel) {
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
        if let id = selectedRequestID, let location = locateRequest(id) {
            addRequest(to: workspace.collections[location.collection].id)
            return
        }
        if let first = workspace.collections.first {
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
        let existing = workspace.collections[location.collection].requests.map(\.name)
        copy.name = (try? CollectionPorting.resolveName(copy.name, suffix: "kopya", existingNames: existing).0)
            ?? "\(copy.name) kopya"
        workspace.collections[location.collection].requests.insert(copy, at: location.request + 1)
        selectedRequestID = copy.id
        persist()
    }

    /// İsteği başka bir koleksiyona taşır (hedefin sonuna eklenir).
    func moveRequest(_ id: UUID, toCollection targetID: UUID) {
        guard let location = locateRequest(id),
              let target = workspace.collections.firstIndex(where: { $0.id == targetID }),
              target != location.collection else { return }
        var request = workspace.collections[location.collection].requests.remove(at: location.request)
        let existing = workspace.collections[target].requests.map(\.name)
        request.name = (try? CollectionPorting.resolveName(request.name, suffix: "taşınan", existingNames: existing).0)
            ?? request.name
        workspace.collections[target].requests.append(request)
        selectedRequestID = request.id
        persist()
    }

    /// Dışarıdan gelen (curl vb.) isteği koleksiyona ekler ve seçer.
    /// Ad çakışması koleksiyon import'uyla aynı kurala göre çözülür.
    func addImportedRequest(_ request: RequestModel, to collectionID: UUID) {
        guard let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        var copy = request
        copy.id = UUID()
        let existing = workspace.collections[index].requests.map(\.name)
        copy.name = (try? CollectionPorting.resolveName(copy.name, suffix: "2", existingNames: existing).0)
            ?? copy.name
        workspace.collections[index].requests.append(copy)
        selectedRequestID = copy.id
        persist()
    }

    func deleteRequest(_ id: UUID) {
        for index in workspace.collections.indices {
            workspace.collections[index].requests.removeAll { $0.id == id }
        }
        if selectedRequestID == id { selectedRequestID = nil }
        persist()
    }

    func addCollection() {
        // Açık arama temizlenir: yeni koleksiyonun adı filtreye uymayacağı için
        // oluşturulur ama listede görünmezdi.
        clearSearch()
        workspace.collections.append(CollectionModel())
        persist()
    }

    func renameCollection(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = workspace.collections.firstIndex(where: { $0.id == id }) else { return }
        workspace.collections[index].name = trimmed
        persist()
    }

    func deleteCollection(_ id: UUID) {
        if let collection = workspace.collections.first(where: { $0.id == id }),
           collection.requests.contains(where: { $0.id == selectedRequestID }) {
            selectedRequestID = nil
        }
        workspace.collections.removeAll { $0.id == id }
        persist()
    }

    /// Sürükle-bırak canlı sıralama: sürüklenen koleksiyonu hedefin konumuna taşır.
    func moveCollection(_ id: UUID, before targetID: UUID) {
        guard id != targetID,
              let from = workspace.collections.firstIndex(where: { $0.id == id }),
              let to = workspace.collections.firstIndex(where: { $0.id == targetID }) else { return }
        workspace.collections.move(
            fromOffsets: IndexSet(integer: from),
            toOffset: to > from ? to + 1 : to
        )
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
    private var responses: [UUID: ResponseState] = [:]
    /// Bellek sınırı: en son bu kadar yanıt saklanır, eskisi düşer.
    private static let retainedResponseLimit = 15
    private var responseOrder: [UUID] = []

    var lastResponse: ResponseState {
        guard let id = selectedRequestID else { return .idle }
        return responses[id] ?? .idle
    }

    var isSending: Bool {
        if case .loading = lastResponse { return true }
        return false
    }

    private func setResponse(_ state: ResponseState, for id: UUID) {
        responses[id] = state
        responseOrder.removeAll { $0 == id }
        responseOrder.append(id)
        while responseOrder.count > Self.retainedResponseLimit {
            responses.removeValue(forKey: responseOrder.removeFirst())
        }
    }

    func send(_ request: RequestModel) {
        flushPendingWrites()
        let id = request.id
        // Aynı isteğin önceki gönderimi hâlâ uçuyorsa iptal et.
        inFlight[id]?.cancel()
        setResponse(.loading, for: id)
        let environment = activeEnvironment

        inFlight[id] = Task { [weak self] in
            guard let self else { return }
            do {
                await self.ensureValidToken(request)
                let response = try await engine.send(request, environment: environment, secretStore: secretStore)
                let display = await Task.detached { AppState.makeDisplay(response) }.value
                try Task.checkCancellation()
                self.setResponse(.success(display), for: id)
                // Referans noktası: "en son bunu test ettim".
                self.recordBaseline(request)
                let data = display.data
                self.recordHistory(
                    request,
                    outcome: .completed(
                        status: data.statusCode,
                        duration: data.duration,
                        byteCount: data.body.count,
                        redirectCount: data.redirects.count
                    ),
                    responseText: display.prettyText
                )
            } catch is CancellationError {
                self.setResponse(.idle, for: id)
            } catch let error as URLError where error.code == .cancelled {
                self.setResponse(.idle, for: id)
            } catch {
                self.setResponse(.failure(error.localizedDescription), for: id)
                self.recordHistory(request, outcome: .failed(message: error.localizedDescription), responseText: nil)
            }
            self.inFlight[id] = nil
        }
    }

    /// Uçuştaki isteği iptal eder. Bağlantı kapanır, kimlik bilgisi taşıyan
    /// istek yarıda kalmaz.
    func cancelSend(_ id: UUID) {
        inFlight[id]?.cancel()
        inFlight[id] = nil
        setResponse(.idle, for: id)
    }

    @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]

    // MARK: - OAuth2

    private let oauthService = OAuth2Service()
    /// Yetkilendirme sürerken arayüzün beklemesi için.
    var authorizingConfigID: UUID?
    var authMessage: String?

    func storedToken(for config: OAuth2Config) -> OAuth2Token? {
        guard let raw = try? secretStore.secret(forName: config.tokenSecretName),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuth2Token.self, from: data)
    }

    /// Client secret `{{secret:isim}}` ile verilmiş olabilir; çözülür.
    private func resolvedClientSecret(_ config: OAuth2Config) -> String? {
        let raw = config.clientSecret.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let resolver = VariableResolver(environment: activeEnvironment, secretStore: secretStore)
        return (try? resolver.resolve(raw)) ?? raw
    }

    private func store(_ token: OAuth2Token, for config: OAuth2Config) throws {
        let data = try JSONEncoder().encode(token)
        // Token vault'a yazılır; workspace dosyasına ASLA.
        try secretStore.setSecret(String(decoding: data, as: UTF8.self), forName: config.tokenSecretName)
        invalidateSecretNames()
    }

    /// Tarayıcıyı açıp yetkilendirme akışını yürütür.
    func authorize(_ config: OAuth2Config) {
        authorizingConfigID = config.id
        authMessage = nil
        Task {
            do {
                let token = try await oauthService.authorize(
                    config: config,
                    resolvedClientSecret: resolvedClientSecret(config),
                    openURL: { url in NSWorkspace.shared.open(url) }
                )
                try store(token, for: config)
                authMessage = "Yetkilendirme tamamlandı."
            } catch {
                authMessage = error.localizedDescription
            }
            authorizingConfigID = nil
        }
    }

    func clearToken(for config: OAuth2Config) {
        try? secretStore.deleteSecret(forName: config.tokenSecretName)
        invalidateSecretNames()
        authMessage = "Token silindi."
    }

    /// Gönderimden önce token'ın geçerli olduğundan emin olur; süresi dolmuşsa
    /// refresh token ile sessizce yeniler.
    private func ensureValidToken(_ request: RequestModel) async {
        guard case .oauth2(let config) = request.auth,
              let token = storedToken(for: config),
              token.isExpired(),
              let refreshToken = token.refreshToken else { return }
        do {
            let renewed = try await oauthService.refresh(
                config: config,
                refreshToken: refreshToken,
                resolvedClientSecret: resolvedClientSecret(config)
            )
            try store(renewed, for: config)
        } catch {
            // Yenileme başarısızsa istek eski token'la gider ve 401 alır;
            // kullanıcı Auth sekmesinden yeniden yetkilendirir.
            authMessage = "Token yenilenemedi: \(error.localizedDescription)"
        }
    }

    // MARK: - Kurum güven deposu (cacerts)

    private(set) var trustStore: TrustStore.LoadResult = .init(entries: [], problems: [])

    func reloadTrustStore() {
        let result = TrustStore.load()
        trustStore = result
        engine.trustStoreCertificates = result.certificates
    }

    func installCertificate(from url: URL) -> String {
        do {
            let destination = try TrustStore.install(from: url)
            reloadTrustStore()
            return "\(destination.lastPathComponent) güven deposuna eklendi."
        } catch {
            return "Eklenemedi: \(error.localizedDescription)"
        }
    }

    func removeCertificate(path: String) -> String {
        do {
            try TrustStore.remove(path: path)
            reloadTrustStore()
            return "Sertifika kaldırıldı."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - TLS profilleri

    func addTLSProfile() -> UUID {
        let profile = TLSProfile()
        workspace.tlsProfiles.append(profile)
        syncTLSProfiles()
        persist()
        return profile.id
    }

    func deleteTLSProfile(_ id: UUID) {
        workspace.tlsProfiles.removeAll { $0.id == id }
        syncTLSProfiles()
        persist()
    }

    func tlsProfileBinding(_ id: UUID) -> Binding<TLSProfile>? {
        guard workspace.tlsProfiles.contains(where: { $0.id == id }) else { return nil }
        let fallback = workspace.tlsProfiles.first { $0.id == id }!
        return Binding(
            get: { self.workspace.tlsProfiles.first { $0.id == id } ?? fallback },
            set: { newValue in
                guard let index = self.workspace.tlsProfiles.firstIndex(where: { $0.id == id }) else { return }
                self.workspace.tlsProfiles[index] = newValue
                self.syncTLSProfiles()
                self.persistSoon()
            }
        )
    }

    /// Motor kendi kopyasını tutar; profil değişince güncellenmeli.
    private func syncTLSProfiles() {
        engine.tlsProfiles = workspace.tlsProfiles
    }

    // MARK: - Çerezler

    private var cookieScope: RequestEngine.Scope {
        RequestEngine.Scope(environmentID: workspace.activeEnvironmentID)
    }

    /// Aktif environment'ın çerez kavanozu (yalnızca bellekte tutulur).
    func activeCookies() -> [HTTPCookie] {
        engine.cookies(in: cookieScope)
    }

    func clearActiveCookies() {
        engine.clearCookies(in: cookieScope)
    }

    /// Ana thread dışında çalışır: büyük gövdeleri biçimlendirmek pahalıdır.
    nonisolated static func makeDisplay(_ response: ResponseData) -> ResponseDisplay {
        let contentType = response.headers
            .first { $0.name.lowercased() == "content-type" }?.value.lowercased() ?? ""
        let text = response.bodyText
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let language: CodeLanguage
        if contentType.contains("json") {
            language = .json
        } else if contentType.contains("xml") || contentType.contains("html") {
            language = .markup
        } else if contentType.contains("javascript") {
            language = .javascript
        } else if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            language = .json
        } else {
            language = .plain
        }

        var pretty = text ?? "(ikili veri: \(response.body.count) byte)"
        if language == .json, let formatted = try? JSONFormatter.beautify(pretty) {
            pretty = formatted
        }
        return ResponseDisplay(data: response, prettyText: pretty, language: language)
    }

    /// Import/export sonucunu (başarı, yeniden adlandırma, uyarılar) kullanıcıya
    /// gösteren alert metni.
    var portingMessage: String?

    enum ImportSource {
        case secora
        case postman
    }

    func importCollection(from url: URL, source: ImportSource) {
        do {
            portingMessage = importCollectionData(try Data(contentsOf: url), source: source)
        } catch {
            portingMessage = "Dosya okunamadı: \(error.localizedDescription)"
        }
    }

    /// Veriyi içe aktarır ve kullanıcıya gösterilecek özet metnini döner.
    /// (Sheet içindeki akışlar mesajı yerinde gösterir, dosya akışı alert'e koyar.)
    @discardableResult
    func importCollectionData(_ data: Data, source: ImportSource) -> String {
        do {
            let existingNames = workspace.collections.map(\.name)
            let outcome: CollectionPorting.ImportOutcome
            switch source {
            case .secora:
                outcome = try CollectionPorting.importSecora(data, existingNames: existingNames)
            case .postman:
                outcome = try CollectionPorting.importPostman(data, existingNames: existingNames)
            }
            workspace.collections.append(outcome.collection)
            persist()

            var lines = ["\"\(outcome.collection.name)\" içe aktarıldı (\(outcome.collection.requests.count) istek)."]
            if outcome.wasRenamed {
                lines.append("İsim çakıştığı için \"\(outcome.collection.name)\" olarak eklendi.")
            }
            lines.append(contentsOf: outcome.warnings.map { "⚠︎ \($0)" })
            return lines.joined(separator: "\n")
        } catch {
            return "İçe aktarma başarısız: \(error.localizedDescription)"
        }
    }

    func exportCollection(_ id: UUID) {
        guard let collection = workspace.collections.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(collection.name).secora.json"
        panel.title = "Koleksiyonu Dışa Aktar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CollectionPorting.exportData(collection).write(to: url)
            portingMessage = "\"\(collection.name)\" dışa aktarıldı.\nSecret değerleri dosyada YOK; yalnızca {{secret:isim}} referansları var."
        } catch {
            portingMessage = "Dışa aktarma başarısız: \(error.localizedDescription)"
        }
    }

    func addEnvironment() -> UUID {
        let environment = EnvironmentModel()
        workspace.environments.append(environment)
        if workspace.activeEnvironmentID == nil {
            workspace.activeEnvironmentID = environment.id
        }
        persist()
        return environment.id
    }

    func deleteEnvironment(_ id: UUID) {
        workspace.environments.removeAll { $0.id == id }
        if workspace.activeEnvironmentID == id {
            workspace.activeEnvironmentID = workspace.environments.first?.id
        }
        persist()
    }

    func environmentBinding(_ id: UUID) -> Binding<EnvironmentModel>? {
        guard let index = workspace.environments.firstIndex(where: { $0.id == id }) else { return nil }
        let fallback = workspace.environments[index]
        return Binding(
            // Index saklanmaz: environment silinince eski index başka kaydı ezerdi.
            get: {
                self.workspace.environments.first { $0.id == id } ?? fallback
            },
            set: { newValue in
                guard let current = self.workspace.environments.firstIndex(where: { $0.id == id }) else { return }
                self.workspace.environments[current] = newValue
                self.persistSoon()
            }
        )
    }

    /// Öneri listesi için: aktif environment değişken adları + "secret:isim" girdileri.
    func templateSuggestions(matching token: String) -> [String] {
        var options: [String] = activeEnvironment?.variables
            .filter { $0.enabled && !$0.key.isEmpty }
            .map(\.key) ?? []
        options += secretNames.map { "secret:\($0)" }
        let query = token.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty
            ? options
            : options.filter { $0.lowercased().contains(query) }
        return Array(filtered.prefix(8))
    }

    func curlCommand(for request: RequestModel, includeSecrets: Bool) -> String {
        do {
            return try CurlExporter.export(
                request,
                environment: activeEnvironment,
                secretStore: secretStore,
                includeSecrets: includeSecrets
            )
        } catch {
            return "# cURL üretilemedi: \(error.localizedDescription)"
        }
    }

    /// Yapısal değişiklikler (ekle/sil/sırala/içe aktar) için anında yazım.
    func persist() {
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
        do {
            try store.save(workspace)
            saveError = nil
            saveState = .saved(Date())
        } catch {
            saveError = "Kaydedilemedi: \(error.localizedDescription)"
            saveState = .failed(error.localizedDescription)
        }
    }
}
