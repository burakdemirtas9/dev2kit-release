import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SecoraCore

/// Swagger / OpenAPI dokümanından koleksiyon oluşturur. Doküman adresten
/// indirilir ya da JSON olarak yapıştırılır/seçilir; önizlenir, oluşan
/// koleksiyon içe aktarma incelemesinden geçer.
struct OpenAPIImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Source: Hashable {
        case address
        case json
    }

    @State private var source: Source = .address
    @State private var address = ""
    @State private var json = ""
    @State private var showingFilePicker = false
    /// Adres değişkeninin değeri. Dokümandaki sunucuyla dolar; göreli ya da
    /// yoksa (yapıştırılan JSON'da sık) kullanıcı girer.
    @State private var serverAddress = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var groups: [OpenAPIDiscovery.Group] = []
    @State private var selectedGroup: OpenAPIDiscovery.Group?
    @State private var document: OpenAPIImporter.Document?
    @State private var variableName = ""
    @State private var addServerToEnvironment = true
    @State private var pendingReview: AppState.PendingImport?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Swagger / OpenAPI'den Koleksiyon")
                .font(.title2).bold()
            Picker("", selection: $source) {
                Text("Adresten").tag(Source.address)
                Text("JSON'dan").tag(Source.json)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .onChange(of: source) { reset() }

            switch source {
            case .address: addressInput
            case .json: jsonInput
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.down)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !groups.isEmpty {
                HStack {
                    Picker("Grup:", selection: $selectedGroup) {
                        ForEach(groups) { group in
                            Text(group.name).tag(OpenAPIDiscovery.Group?.some(group))
                        }
                    }
                    .frame(maxWidth: 320)
                    Button("Bu Grubu Getir") {
                        if let selectedGroup { load(selectedGroup.url.absoluteString) }
                    }
                    .disabled(selectedGroup == nil || loading)
                }
            }

            if let document {
                preview(document)
            }
            Spacer()

            Divider()
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Devam") { prepare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(document == nil || variableName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.json]) { picked in
            guard case .success(let url) = picked else { return }
            readFile(url)
        }
        .sheet(item: $pendingReview) { pending in
            ImportReviewView(
                items: pending.items,
                onConfirm: { finish(pending.items) },
                onCancel: { pendingReview = nil }
            )
        }
    }

    private var addressInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Doküman ya da Swagger UI adresi (ör. http://localhost:8080/v3/api-docs veya …/swagger-ui/index.html). OpenAPI 3 ve Swagger 2, JSON biçiminde.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("http://localhost:8080/v3/api-docs", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(fetch)
                Button(action: fetch) {
                    if loading { ProgressView().controlSize(.small) } else { Text("Getir") }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || loading)
            }
        }
    }

    private var jsonInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("/v3/api-docs yanıtını yapıştır ya da kayıtlı JSON dosyasını seç. OpenAPI 3 ve Swagger 2.")
                .font(.caption)
                .foregroundStyle(.secondary)
            CodeEditor(text: $json, language: .json)
                .frame(height: 100)
                .background(Theme.editorBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button {
                    json = NSPasteboard.general.string(forType: .string) ?? ""
                    parseJSON()
                } label: {
                    Label("Panodan Yapıştır", systemImage: "doc.on.clipboard")
                }
                Button {
                    showingFilePicker = true
                } label: {
                    Label("Dosya Seç…", systemImage: "folder")
                }
                Spacer()
                // Büyük dokümanı her tuşta yeniden çözümlememek için elle tetiklenir.
                Button("Oku", action: parseJSON)
                    .disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func preview(_ document: OpenAPIImporter.Document) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(document.title).font(.headline)
                if let version = document.version {
                    Text("v\(version)").foregroundStyle(.secondary)
                }
                Text(document.specVersion.hasPrefix("2") ? "Swagger \(document.specVersion)" : "OpenAPI \(document.specVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(document.operationCount) işlem")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Sunucu") {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("https://gateway.ornek.com/servis", text: $serverAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    if document.serverURL == nil {
                        Text("Dokümanda mutlak sunucu adresi yok; isteklerin gideceği adresi gir.")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
            LabeledContent("Adres değişkeni") {
                HStack(spacing: 4) {
                    Text("{{").foregroundStyle(.secondary)
                    TextField("değişken", text: $variableName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Text("}}/yol").foregroundStyle(.secondary)
                }
            }
            environmentOption(document)
        }
        .padding(12)
        .background(Theme.editorBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func environmentOption(_ document: OpenAPIImporter.Document) -> some View {
        let name = variableName.trimmingCharacters(in: .whitespaces)
        let server = serverAddress.trimmingCharacters(in: .whitespaces)
        if let environment = appState.activeEnvironment, !server.isEmpty {
            if environment.variables.contains(where: { $0.key == name }) {
                Label("{{\(name)}} \"\(environment.name)\" environment'ında zaten tanımlı; değeri değiştirilmez.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.up)
            } else {
                Toggle("{{\(name)}} = \(server) olarak \"\(environment.name)\" environment'ına ekle", isOn: $addServerToEnvironment)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        } else if appState.activeEnvironment == nil {
            Label("Aktif environment yok; {{\(name)}} değişkenini bir environment'a elle ekle.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Theme.warning)
        }
    }

    // MARK: - Akış

    private func fetch() { load(address) }

    private func load(_ target: String) {
        loading = true
        errorMessage = nil
        document = nil
        Task {
            do {
                switch try await appState.discoverOpenAPI(target) {
                case .document(let found):
                    show(found)
                case .groups(let found):
                    groups = found
                    selectedGroup = found.first
                    errorMessage = nil
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }

    private func show(_ found: OpenAPIImporter.Document) {
        document = found
        variableName = found.suggestedName
        serverAddress = found.serverURL ?? ""
    }

    private func reset() {
        document = nil
        groups = []
        errorMessage = nil
    }

    /// Yapıştırılan ya da dosyadan gelen doküman. Adres olmadığı için göreli
    /// sunucu adresleri çözülemez; kullanıcı önizlemede girer.
    private func parseJSON() {
        let data = Data(json.utf8)
        guard data.count <= ImportReviewer.maxImportBytes else {
            errorMessage = "Doküman çok büyük; en fazla \(ImportReviewer.maxImportBytes / 1_048_576) MB."
            return
        }
        do {
            show(try OpenAPIImporter.parse(data, sourceURL: nil))
            errorMessage = nil
        } catch {
            document = nil
            errorMessage = error.localizedDescription
        }
    }

    private func readFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ImportReviewer.maxImportBytes else {
            errorMessage = "Dosya çok büyük; en fazla \(ImportReviewer.maxImportBytes / 1_048_576) MB."
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Dosya okunamadı."
            return
        }
        json = String(decoding: data, as: UTF8.self)
        parseJSON()
    }

    private func prepare() {
        guard let document else { return }
        switch appState.prepareOpenAPIImport(document, variableName: variableName.trimmingCharacters(in: .whitespaces)) {
        case .success(let prepared):
            // Sunucu adresinin nereye gittiği her zaman görülsün diye inceleme
            // ekranı temiz içe aktarmada da gösterilir.
            pendingReview = AppState.PendingImport(items: [prepared])
        case .failure(let failure):
            errorMessage = failure.message
        }
    }

    private func finish(_ items: [AppState.PreparedImport]) {
        pendingReview = nil
        if addServerToEnvironment {
            appState.addVariableToActiveEnvironmentIfMissing(variableName.trimmingCharacters(in: .whitespaces), value: serverAddress)
        }
        appState.portingMessage = appState.commitImport(items)
        dismiss()
    }
}
