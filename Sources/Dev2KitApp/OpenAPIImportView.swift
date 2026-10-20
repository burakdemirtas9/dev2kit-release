import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Dev2KitCore

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

    /// Otomatik içe aktarmadan gelen doküman: JSON sekmesinde hazır açılır.
    private let initialJSON: String?

    init(initialJSON: String? = nil) {
        self.initialJSON = initialJSON
        if let initialJSON {
            _source = State(initialValue: .json)
            _json = State(initialValue: initialJSON)
        }
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
            Text(L10n.t("openapi.title"))
                .font(.title2).bold()
            Picker("", selection: $source) {
                Text(L10n.t("openapi.fromURL")).tag(Source.address)
                Text(L10n.t("openapi.fromJSON")).tag(Source.json)
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
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !groups.isEmpty {
                HStack {
                    Picker(L10n.t("openapi.group"), selection: $selectedGroup) {
                        ForEach(groups) { group in
                            Text(group.name).tag(OpenAPIDiscovery.Group?.some(group))
                        }
                    }
                    .frame(maxWidth: 320)
                    Button(L10n.t("openapi.fetchGroup")) {
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
                Button(L10n.t("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("common.continue")) { prepare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(document == nil || variableName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .onAppear { if initialJSON != nil, document == nil { parseJSON() } }
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
            Text(L10n.t("openapi.url.help"))
                .font(.secondaryText)
                .foregroundStyle(.secondary)
            HStack {
                TextField("http://localhost:8080/v3/api-docs", text: $address)
                    .inputLimit(.url)
                    .textFieldStyle(.input)
                    .onSubmit(fetch)
                Button(action: fetch) {
                    if loading { ProgressView().controlSize(.small) } else { Text(L10n.t("openapi.fetch")) }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || loading)
            }
        }
    }

    private var jsonInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("openapi.json.help"))
                .font(.secondaryText)
                .foregroundStyle(.secondary)
            ImportTextEditor(text: $json, language: .json)
                .frame(height: 100)
                .background(Theme.editorBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button {
                    let pasted = NSPasteboard.general.string(forType: .string) ?? ""
                    if let rejection = InputLimits.rejection(of: pasted, maxBytes: InputLimits.maxImportBytes, maxLines: InputLimits.maxImportLines) {
                        errorMessage = rejection
                    } else {
                        json = pasted
                        parseJSON()
                    }
                } label: {
                    Label(L10n.t("openapi.paste"), systemImage: "doc.on.clipboard")
                }
                Button {
                    showingFilePicker = true
                } label: {
                    Label(L10n.t("auto.chooseFile"), systemImage: "folder")
                }
                Spacer()
                // Büyük dokümanı her tuşta yeniden çözümlememek için elle tetiklenir.
                Button(L10n.t("openapi.read"), action: parseJSON)
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
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.plural("openapi.operations", count: document.operationCount))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L10n.t("openapi.server")) {
                VStack(alignment: .leading, spacing: 2) {
                    TextField(L10n.t("openapi.server.placeholder"), text: $serverAddress)
                        .inputLimit(.url)
                        .textFieldStyle(.input)
                        .font(.system(.callout, design: .monospaced))
                    if document.serverURL == nil {
                        Text(L10n.t("openapi.server.missing"))
                            .font(.secondaryText)
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
            LabeledContent(L10n.t("openapi.variable")) {
                HStack(spacing: 4) {
                    Text("{{").foregroundStyle(.secondary)
                    TextField(L10n.t("openapi.variable.placeholder"), text: $variableName)
                        .inputLimit(.short)
                        .textFieldStyle(.input)
                        .frame(width: 220)
                    Text(L10n.t("openapi.variable.suffix")).foregroundStyle(.secondary)
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
                Label(L10n.t("openapi.variable.exists", name, environment.name), systemImage: "checkmark.circle")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.up)
            } else {
                Toggle(L10n.t("openapi.variable.add", name, server, environment.name), isOn: $addServerToEnvironment)
                    .toggleStyle(.checkbox)
                    .font(.secondaryText)
            }
        } else if appState.activeEnvironment == nil {
            Label(L10n.t("openapi.variable.noEnvironment", name), systemImage: "exclamationmark.triangle")
                .font(.secondaryText)
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
            errorMessage = L10n.t("openapi.documentTooLarge", L10n.number(ImportReviewer.maxImportBytes / 1_048_576))
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
            errorMessage = L10n.t("openapi.fileTooLarge", L10n.number(ImportReviewer.maxImportBytes / 1_048_576))
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = L10n.t("openapi.fileUnreadable")
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
