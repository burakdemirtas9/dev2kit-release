import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import BoltDockCore

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

/// Uygulamanın tek merkezi durumu. Workspace değişiklikleri debounce'suz,
/// her mutasyondan sonra diske yazılır (MVP için yeterli; dosya küçük).
@Observable
@MainActor
final class AppState {
    var workspace: WorkspaceModel
    var selectedRequestID: UUID?
    var lastResponse: ResponseState = .idle
    var saveError: String?

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

    func addRequest(to collectionID: UUID) {
        guard let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        let request = RequestModel()
        workspace.collections[index].requests.append(request)
        selectedRequestID = request.id
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

    func send(_ request: RequestModel) {
        flushPendingWrites()
        lastResponse = .loading
        let environment = activeEnvironment
        // Nesil sayacı: arka arkaya gönderilen isteklerde geç gelen eski yanıt
        // yenisinin üzerine yazmasın.
        sendGeneration &+= 1
        let generation = sendGeneration
        Task {
            do {
                let response = try await engine.send(request, environment: environment, secretStore: secretStore)
                let display = await Task.detached { AppState.makeDisplay(response) }.value
                guard generation == self.sendGeneration else { return }
                lastResponse = .success(display)
            } catch {
                guard generation == self.sendGeneration else { return }
                lastResponse = .failure(error.localizedDescription)
            }
        }
    }

    @ObservationIgnored private var sendGeneration = 0

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
        case boltdock
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
            case .boltdock:
                outcome = try CollectionPorting.importBoltDock(data, existingNames: existingNames)
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
        panel.nameFieldStringValue = "\(collection.name).boltdock.json"
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
        } catch {
            saveError = "Kaydedilemedi: \(error.localizedDescription)"
        }
    }
}
