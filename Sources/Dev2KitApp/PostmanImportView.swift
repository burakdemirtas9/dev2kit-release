import SwiftUI
import Dev2KitCore

/// Postman hesabından koleksiyonları otomatik çekip içe aktaran ekran.
///
/// Postman uygulaması koleksiyonları yerelde binary IndexedDB içinde tuttuğu
/// için (sürümle kırılgan), güvenilir yol resmî Postman API'sidir. Kullanıcının
/// API anahtarı şifreli vault'ta `postman_api_key` adıyla saklanır ve yalnızca
/// api.getpostman.com'a gönderilir.
struct PostmanImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput = ""
    @State private var connected = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var collections: [PostmanAPIClient.CollectionSummary] = []
    @State private var selectedUIDs: Set<String> = []
    @State private var importingUID: String?
    /// Bulgu çıkan içe aktarma: kullanıcının kararını bekler.
    @State private var pendingReview: AppState.PendingImport?
    /// İncelemedeki koleksiyonun Postman kimliği; onaylanınca "aktarıldı" işaretlenir.
    @State private var pendingUIDs: [UUID: String] = [:]
    /// İndirme ya da dönüştürme hataları; inceleme sonrası özete eklenir.
    @State private var pendingFailures: [String] = []
    @State private var isImporting = false
    @State private var importedUIDs: Set<String> = []
    @State private var lastResultMessage: String?

    // static: View struct her render'da yeniden kurulduğu için örnek alan
    // olsaydı her seferinde yeni bir URLSession açılırdı.
    private static let client = PostmanAPIClient()
    private var client: PostmanAPIClient { Self.client }
    private static let keyName = "postman_api_key"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Postman'den Otomatik Al")
                .font(.title2).bold()

            if connected {
                collectionList
            } else {
                keySetup
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .lineLimit(3)
            }
            if let lastResultMessage {
                ScrollView {
                    Text(lastResultMessage)
                        .font(.secondaryText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }

            HStack {
                if connected {
                    Button("API Anahtarını Değiştir") {
                        connected = false
                        collections = []
                        errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("Kapat") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .onAppear(perform: connectWithStoredKeyIfAvailable)
        .sheet(item: $pendingReview) { pending in
            ImportReviewView(
                items: pending.items,
                onConfirm: { finishImport(pending.items) },
                onCancel: {
                    pendingReview = nil
                    lastResultMessage = (["İçe aktarmadan vazgeçildi."] + pendingFailures).joined(separator: "\n")
                }
            )
        }
    }

    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Postman koleksiyonların hesabına senkronlanır; buradan otomatik çekmek için bir Postman API anahtarı gerekir:")
                .font(.callout)
            Text("postman.co → sağ üst profil → Settings → API Keys → Generate API Key")
                .font(.secondaryMono)
                .foregroundStyle(.secondary)
            Text("Anahtar şifreli vault'ta saklanır ve yalnızca api.getpostman.com'a gönderilir.")
                .font(.secondaryText)
                .foregroundStyle(.secondary)

            HStack {
                SecureField("PMAK-...", text: $apiKeyInput)
                    .inputLimit(.credential)
                    .textFieldStyle(.input)
                Button("Bağlan") { connect(with: apiKeyInput) }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || loading)
            }
            if loading { ProgressView().controlSize(.small) }
            Spacer()
        }
    }

    /// Henüz aktarılmamış, dolayısıyla seçilebilir koleksiyonlar.
    private var selectableCollections: [PostmanAPIClient.CollectionSummary] {
        collections.filter { !importedUIDs.contains($0.id) }
    }

    private var allSelected: Bool {
        !selectableCollections.isEmpty && selectedUIDs.count == selectableCollections.count
    }

    private var collectionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Aktarılacak koleksiyonları seç:")
                    .font(.callout)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading || isImporting)
                .help("Listeyi yenile")
            }

            if loading && collections.isEmpty {
                ProgressView("Koleksiyonlar yükleniyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if collections.isEmpty {
                ContentUnavailableView(
                    "Koleksiyon yok",
                    systemImage: "tray",
                    description: Text("Bu hesapta koleksiyon bulunamadı.")
                )
            } else {
                Toggle("Hepsini Seç", isOn: Binding(
                    get: { allSelected },
                    set: { selectAll in
                        selectedUIDs = selectAll ? Set(selectableCollections.map(\.id)) : []
                    }
                ))
                .toggleStyle(.checkbox)
                .disabled(selectableCollections.isEmpty || isImporting)

                List(collections) { summary in
                    HStack {
                        if importedUIDs.contains(summary.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.up)
                            Text(summary.name)
                            Spacer()
                            Text("Aktarıldı")
                                .font(.secondaryText)
                                .foregroundStyle(.secondary)
                        } else {
                            Toggle(isOn: Binding(
                                get: { selectedUIDs.contains(summary.id) },
                                set: { isOn in
                                    if isOn { selectedUIDs.insert(summary.id) }
                                    else { selectedUIDs.remove(summary.id) }
                                }
                            )) {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(Theme.purple)
                                    Text(summary.name)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(isImporting)
                            Spacer()
                            if importingUID == summary.id {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
                .listStyle(.inset)

                HStack {
                    Spacer()
                    Button {
                        importSelected()
                    } label: {
                        if isImporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Seçilenleri Aktar (\(selectedUIDs.count))", systemImage: "square.and.arrow.down")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedUIDs.isEmpty || isImporting)
                }
            }
        }
    }

    // MARK: - Akış

    private func connectWithStoredKeyIfAvailable() {
        guard let stored = try? appState.secretStore.secret(forName: Self.keyName), !stored.isEmpty else {
            return
        }
        connect(with: stored, saveKey: false)
    }

    private func connect(with key: String, saveKey: Bool = true) {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        loading = true
        errorMessage = nil
        Task {
            do {
                let list = try await client.listCollections(apiKey: trimmed)
                if saveKey {
                    try? appState.secretStore.setSecret(trimmed, forName: Self.keyName)
                    appState.invalidateSecretNames()
                }
                collections = list
                connected = true
                apiKeyInput = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }

    private func refresh() {
        guard let stored = try? appState.secretStore.secret(forName: Self.keyName) else { return }
        connect(with: stored, saveKey: false)
    }

    /// Seçilen koleksiyonları sırayla çeker ve inceler. Bulgu yoksa hemen
    /// aktarır; varsa hepsini tek inceleme ekranında gösterir. Biri indirilemese
    /// de kalanlarla devam edilir.
    private func importSelected() {
        guard let key = try? appState.secretStore.secret(forName: Self.keyName) else {
            errorMessage = "API anahtarı bulunamadı; yeniden bağlan."
            connected = false
            return
        }
        let targets = collections.filter { selectedUIDs.contains($0.id) }
        isImporting = true
        errorMessage = nil
        Task {
            var prepared: [AppState.PreparedImport] = []
            var uids: [UUID: String] = [:]
            var failures: [String] = []
            for summary in targets {
                importingUID = summary.id
                do {
                    let data = try await client.fetchCollectionData(uid: summary.id, apiKey: key)
                    let reserved = prepared.map(\.review.collection.name)
                    switch appState.prepareImport(data, source: .postman, reservedNames: reserved) {
                    case .success(let item):
                        prepared.append(item)
                        uids[item.id] = summary.id
                    case .failure(let failure):
                        failures.append("✗ \"\(summary.name)\": \(failure.message)")
                    }
                } catch {
                    failures.append("✗ \"\(summary.name)\" çekilemedi: \(error.localizedDescription)")
                }
            }
            importingUID = nil
            isImporting = false
            pendingUIDs = uids
            pendingFailures = failures
            if prepared.isEmpty {
                lastResultMessage = failures.joined(separator: "\n")
            } else if prepared.allSatisfy(\.review.isClean) {
                finishImport(prepared)
            } else {
                pendingReview = AppState.PendingImport(items: prepared)
            }
        }
    }

    private func finishImport(_ items: [AppState.PreparedImport]) {
        pendingReview = nil
        let report = appState.commitImport(items)
        for item in items {
            if let uid = pendingUIDs[item.id] {
                importedUIDs.insert(uid)
                selectedUIDs.remove(uid)
            }
        }
        lastResultMessage = ([report.plainText] + pendingFailures).joined(separator: "\n")
    }
}
