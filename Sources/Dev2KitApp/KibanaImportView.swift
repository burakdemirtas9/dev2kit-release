import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Dev2KitCore

/// Kibana'dan kopyalanan gelen-istek log kaydından istek oluşturur.
/// Neyin alınacağı (adres, gövde, hangi başlıklar) içe aktarmadan önce seçilir;
/// hassas başlıklar varsayılan olarak alınmaz.
struct KibanaImportView: View {
    /// Otomatik içe aktarmadan gelen kayıt: hazır açılır.
    private let initialJSON: String?

    init(initialJSON: String? = nil) {
        self.initialJSON = initialJSON
        if let initialJSON { _json = State(initialValue: initialJSON) }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var json = ""
    @State private var result: KibanaImporter.ParseResult?
    @State private var parseError: String?
    @State private var entryID: String?
    @State private var options = KibanaImporter.Options(selectedHeaders: [])
    @State private var applyToSelected = false
    /// Varsayılan: koleksiyonsuz. Kullanıcı isterse mevcut ya da yeni bir koleksiyon seçer.
    @State private var destination: DestinationChoice = .ungrouped
    @State private var newCollectionName = ""
    @State private var gatewayAddress = ""
    @State private var showingFilePicker = false
    @State private var importError: String?

    private var entry: KibanaImporter.Entry? {
        result?.entries.first { $0.id == entryID } ?? result?.entries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("kibana.title"))
                .font(.title2).bold()
            Text(L10n.t("kibana.subtitle"))
                .font(.secondaryText)
                .foregroundStyle(.secondary)

            input
            if let parseError {
                Label(parseError, systemImage: "xmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
            }
            ForEach(result?.rejected ?? [], id: \.self) { reason in
                Label(reason, systemImage: "hand.raised.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let entry {
                ScrollView {
                    selection(for: entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 680, height: 680)
        .onAppear { if initialJSON != nil { reparse() } }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.json]) { picked in
            guard case .success(let url) = picked else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            // Boyut okumadan ÖNCE: OpenAPI içe aktarmasıyla aynı sınır.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > InputLimits.maxImportBytes {
                parseError = L10n.t("kibana.fileTooLarge", TextStats.size(InputLimits.maxImportBytes))
            } else if let data = try? Data(contentsOf: url) {
                json = String(decoding: data, as: UTF8.self)
            } else {
                parseError = L10n.t("openapi.fileUnreadable")
            }
        }
    }

    // MARK: - Girdi

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            ImportTextEditor(text: $json, language: .json)
                .frame(height: 90)
                .background(Theme.editorBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .onChange(of: json) { reparse() }
            HStack {
                Button {
                    let pasted = NSPasteboard.general.string(forType: .string) ?? ""
                    if let rejection = InputLimits.rejection(of: pasted, maxBytes: InputLimits.maxImportBytes, maxLines: InputLimits.maxImportLines) {
                        parseError = rejection
                    } else {
                        json = pasted
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
                if let entries = result?.entries, entries.count > 1 {
                    Picker(L10n.t("kibana.record"), selection: Binding(
                        get: { entryID ?? entries.first?.id },
                        set: { selectEntry($0) }
                    )) {
                        ForEach(entries) { entry in
                            Text("\(entry.method.rawValue) \(entry.path) \(entry.loggedAt ?? "")")
                                .tag(String?.some(entry.id))
                        }
                    }
                    .frame(maxWidth: 320)
                }
            }
        }
    }

    // MARK: - Seçim

    @ViewBuilder
    private func selection(for entry: KibanaImporter.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(entry.method.rawValue)
                    .font(.secondaryMono).bold()
                    .foregroundStyle(Theme.purple)
                Text(entry.path)
                    .font(.secondaryMono)
                    .lineLimit(1)
                Spacer()
                Text("\(entry.environment ?? L10n.t("kibana.unknownEnvironment")) · \(entry.serviceName)\(entry.loggedStatus.map { " · \($0)" } ?? "")")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
            ForEach(entry.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            }

            Picker(L10n.t("kibana.target"), selection: $applyToSelected) {
                Text(L10n.t("kibana.target.new")).tag(false)
                Text(L10n.t("kibana.target.selected")).tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(appState.selectedRequest == nil)
            .frame(maxWidth: 360)

            Toggle(isOn: $options.includeURL) {
                sectionLabel(L10n.t("kibana.section.url"), detail: entry.urlTemplate)
            }
            if options.includeURL {
                variableField(for: entry)
            }
            Toggle(isOn: $options.includeBody) {
                sectionLabel("Body", detail: entry.body.map { L10n.plural("kibana.characters", count: $0.count) } ?? L10n.t("kibana.noBody"))
            }
            .disabled(entry.body == nil)
            Toggle(isOn: $options.includeHeaders) {
                sectionLabel("Headers", detail: L10n.t("kibana.headersSelected", L10n.number(selectedCount(entry)), L10n.number(entry.headers.count - dropped(entry).count)))
            }
            if options.includeHeaders {
                headerGroups(for: entry)
                    .padding(.leading, 20)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func sectionLabel(_ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.semibold)
            Text(detail)
                .font(.secondaryMono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Adres değişkeni aktif environment'ta yoksa gateway adresi burada girilir.
    @ViewBuilder
    private func variableField(for entry: KibanaImporter.Entry) -> some View {
        let defined = appState.activeEnvironment?.variables.contains { $0.key == entry.variableName } ?? false
        Group {
            if defined {
                Label(L10n.t("kibana.variable.defined", entry.variableName), systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.up)
            } else if let environment = appState.activeEnvironment {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L10n.t("kibana.gateway.placeholder"), text: $gatewayAddress)
                        .inputLimit(.url)
                        .textFieldStyle(.input)
                        .frame(maxWidth: 420)
                    Text(L10n.t("kibana.variable.willAdd", entry.variableName, environment.name))
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(L10n.t("openapi.variable.noEnvironment", entry.variableName),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
            }
        }
        .font(.secondaryText)
        .padding(.leading, 20)
    }

    @ViewBuilder
    private func headerGroups(for entry: KibanaImporter.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([HeaderCategory.normal, .sensitive, .infrastructure], id: \.self) { category in
                let headers = entry.headers.filter { $0.category == category }
                if !headers.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(headers) { header in
                                Toggle(isOn: headerBinding(header.id)) {
                                    headerRow(header)
                                }
                            }
                        }
                        .padding(.leading, 4)
                    } label: {
                        Toggle(isOn: groupBinding(headers)) {
                            groupLabel(category, headers: headers)
                        }
                    }
                }
            }
            let droppedNames = dropped(entry).map(\.name).joined(separator: ", ")
            if !droppedNames.isEmpty {
                Label(L10n.t("kibana.dropped", droppedNames), systemImage: "nosign")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func groupLabel(_ category: HeaderCategory, headers: [ClassifiedHeader]) -> some View {
        let selected = headers.filter { options.selectedHeaders.contains($0.id) }.count
        return HStack(spacing: 6) {
            Text("\(category.title) (\(L10n.number(selected))/\(L10n.number(headers.count)))")
            switch category {
            case .sensitive:
                Text(L10n.t("kibana.sensitive.note"))
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            case .infrastructure:
                Text(L10n.t("kibana.trace.note"))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    /// Hassas değerler ekranda maskelenir; seçen kişi değeri zaten yapıştırdı,
    /// ama ekran paylaşımında ya da ekran görüntüsünde görünmesin.
    private func headerRow(_ header: ClassifiedHeader) -> some View {
        HStack(spacing: 8) {
            Text(header.name)
                .font(.secondaryMono)
            Group {
                if header.sensitiveKind != nil {
                    Text(L10n.plural("kibana.masked", count: header.value.count))
                } else {
                    Text(header.value)
                }
            }
            .font(.secondaryMono)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            if header.sensitiveKind == .credential {
                tag(L10n.t("kibana.tag.vault"), color: Theme.up)
            } else if header.sensitiveKind == .personal {
                tag(L10n.t("kibana.tag.personal"), color: Theme.warning)
            }
            if header.isExpired() {
                tag(L10n.t("kibana.tag.expired"), color: Theme.down)
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.tinyText).bold()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Alt çubuk

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let importError {
                Label(importError, systemImage: "xmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if !applyToSelected {
                    destinationPicker
                }
                Spacer()
                Button(L10n.t("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(applyToSelected ? L10n.t("kibana.apply") : L10n.t("import.menu.title")) { performImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
    }

    private var canImport: Bool {
        guard entry != nil, options.includeURL || options.includeBody || options.includeHeaders else { return false }
        if applyToSelected { return appState.selectedRequest != nil }
        if destination == .newCollection {
            return !newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    enum DestinationChoice: Hashable {
        case ungrouped
        case existing(UUID)
        case newCollection
    }

    private var destinationPicker: some View {
        HStack(spacing: 8) {
            Picker(L10n.t("import.addTo"), selection: $destination) {
                Label(L10n.t("collection.ungrouped"), systemImage: "tray").tag(DestinationChoice.ungrouped)
                let collections = appState.workspace.regularCollections
                if !collections.isEmpty {
                    Divider()
                    ForEach(collections) { collection in
                        Text(collection.name).tag(DestinationChoice.existing(collection.id))
                    }
                }
                Divider()
                Label(L10n.t("import.newCollection"), systemImage: "folder.badge.plus").tag(DestinationChoice.newCollection)
            }
            .frame(maxWidth: 240)
            if destination == .newCollection {
                VStack(alignment: .leading, spacing: 2) {
                    TextField(L10n.t("collection.name.placeholder"), text: $newCollectionName)
                        .inputLimit(.name)
                        .textFieldStyle(.input)
                        .frame(width: 170)
                    if appState.existingCollection(named: newCollectionName) != nil {
                        Text(L10n.t("import.collectionExists"))
                            .font(.tinyText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Durum

    private func headerBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { options.selectedHeaders.contains(id) },
            set: { isOn in
                if isOn { options.selectedHeaders.insert(id) } else { options.selectedHeaders.remove(id) }
            }
        )
    }

    private func groupBinding(_ headers: [ClassifiedHeader]) -> Binding<Bool> {
        Binding(
            // Süresi dolmuşlar grup seçimine dahil değil; onlar yüzünden grup
            // hiç "seçili" görünmezse ikinci tıklama hiçbir şey yapmazdı.
            get: {
                let live = headers.filter { !$0.isExpired() }
                return (live.isEmpty ? headers : live).allSatisfy { options.selectedHeaders.contains($0.id) }
            },
            set: { isOn in
                // Grup seçilse de süresi dolmuş token alınmaz; gerekirse tek tek seçilir.
                let ids = headers.filter { !isOn || !$0.isExpired() }.map(\.id)
                if isOn { options.selectedHeaders.formUnion(ids) } else { options.selectedHeaders.subtract(ids) }
            }
        )
    }

    private func dropped(_ entry: KibanaImporter.Entry) -> [ClassifiedHeader] {
        entry.headers.filter { $0.category == .dropped }
    }

    private func selectedCount(_ entry: KibanaImporter.Entry) -> Int {
        entry.headers.filter { $0.category != .dropped && options.selectedHeaders.contains($0.id) }.count
    }

    private func selectEntry(_ id: String?) {
        entryID = id
        options.selectedHeaders = entry?.defaultHeaderSelection ?? []
        options.includeBody = entry?.body != nil
        gatewayAddress = ""
    }

    private func reparse() {
        importError = nil
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            result = nil
            parseError = nil
            return
        }
        do {
            result = try KibanaImporter.parse(Data(trimmed.utf8))
            parseError = nil
            selectEntry(result?.entries.first?.id)
        } catch {
            result = nil
            parseError = error.localizedDescription
        }
    }

    private func performImport() {
        guard let entry else { return }
        let base = applyToSelected ? appState.selectedRequest?.wrappedValue : nil
        let output = KibanaImporter.build(entry, options: options, onto: base)
        let target: AppState.KibanaImportTarget
        if applyToSelected {
            target = .selectedRequest
        } else {
            switch destination {
            case .ungrouped: target = .newRequest(.ungrouped)
            case .existing(let id): target = .newRequest(.existing(id))
            case .newCollection: target = .newRequest(.new(name: newCollectionName))
            }
        }
        do {
            try appState.importFromKibana(
                output,
                target: target,
                variable: options.includeURL ? (entry.variableName, gatewayAddress.trimmingCharacters(in: .whitespaces)) : nil
            )
            dismiss()
        } catch {
            importError = L10n.t("kibana.vaultFailed", error.localizedDescription)
        }
    }
}
