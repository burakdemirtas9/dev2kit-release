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
            Text("Kibana'dan İstek")
                .font(.title2).bold()
            Text("Kibana'da kaydı açıp JSON halini kopyala ya da dışa aktarılan dosyayı seç. Her ortamın logu aktarılır; veri yalnızca bu Mac'te işlenir.")
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
                parseError = "Dosya çok büyük; en fazla \(TextStats.size(InputLimits.maxImportBytes))."
            } else if let data = try? Data(contentsOf: url) {
                json = String(decoding: data, as: UTF8.self)
            } else {
                parseError = "Dosya okunamadı."
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
                    Label("Panodan Yapıştır", systemImage: "doc.on.clipboard")
                }
                Button {
                    showingFilePicker = true
                } label: {
                    Label("Dosya Seç…", systemImage: "folder")
                }
                Spacer()
                if let entries = result?.entries, entries.count > 1 {
                    Picker("Kayıt:", selection: Binding(
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
                Text("\(entry.environment ?? "ortam bilinmiyor") · \(entry.serviceName)\(entry.loggedStatus.map { " · \($0)" } ?? "")")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
            ForEach(entry.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            }

            Picker("Hedef:", selection: $applyToSelected) {
                Text("Yeni istek").tag(false)
                Text("Seçili isteğe uygula").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(appState.selectedRequest == nil)
            .frame(maxWidth: 360)

            Toggle(isOn: $options.includeURL) {
                sectionLabel("URL ve metot", detail: entry.urlTemplate)
            }
            if options.includeURL {
                variableField(for: entry)
            }
            Toggle(isOn: $options.includeBody) {
                sectionLabel("Gövde", detail: entry.body.map { "\($0.count) karakter" } ?? "logda gövde yok")
            }
            .disabled(entry.body == nil)
            Toggle(isOn: $options.includeHeaders) {
                sectionLabel("Başlıklar", detail: "\(selectedCount(entry)) / \(entry.headers.count - dropped(entry).count) seçili")
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
                Label("{{\(entry.variableName)}} aktif environment'ta tanımlı.", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.up)
            } else if let environment = appState.activeEnvironment {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Gateway adresi, ör. https://gateway.ornek.com", text: $gatewayAddress)
                        .inputLimit(.url)
                        .textFieldStyle(.input)
                        .frame(maxWidth: 420)
                    Text("{{\(entry.variableName)}} \"\(environment.name)\" environment'ına eklenir. Boş bırakırsan gönderirken tanımsız değişken uyarısı alırsın.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Aktif environment yok; {{\(entry.variableName)}} değişkenini bir environment'a elle ekle.",
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
                Label("\(droppedNames) her zaman atılır: hedefle ve gövdeyle çakışır.", systemImage: "nosign")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func groupLabel(_ category: HeaderCategory, headers: [ClassifiedHeader]) -> some View {
        let selected = headers.filter { options.selectedHeaders.contains($0.id) }.count
        return HStack(spacing: 6) {
            Text("\(category.title) (\(selected)/\(headers.count))")
            switch category {
            case .sensitive:
                Text("token/cookie vault'a taşınır · kişisel veri düz metin kalır (KVKK)")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            case .infrastructure:
                Text("başka bir isteğin izine ait")
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
                    Text("•••• (\(header.value.count) karakter)")
                } else {
                    Text(header.value)
                }
            }
            .font(.secondaryMono)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            if header.sensitiveKind == .credential {
                tag("vault", color: Theme.up)
            } else if header.sensitiveKind == .personal {
                tag("kişisel", color: Theme.warning)
            }
            if header.isExpired() {
                tag("süresi dolmuş", color: Theme.down)
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
                Button("Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(applyToSelected ? "Uygula" : "İçe Aktar") { performImport() }
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
            Picker("Ekle:", selection: $destination) {
                Label(CollectionModel.ungroupedName, systemImage: "tray").tag(DestinationChoice.ungrouped)
                let collections = appState.workspace.regularCollections
                if !collections.isEmpty {
                    Divider()
                    ForEach(collections) { collection in
                        Text(collection.name).tag(DestinationChoice.existing(collection.id))
                    }
                }
                Divider()
                Label("Yeni koleksiyon…", systemImage: "folder.badge.plus").tag(DestinationChoice.newCollection)
            }
            .frame(maxWidth: 240)
            if destination == .newCollection {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Koleksiyon adı", text: $newCollectionName)
                        .inputLimit(.name)
                        .textFieldStyle(.input)
                        .frame(width: 170)
                    if appState.existingCollection(named: newCollectionName) != nil {
                        Text("Bu adla bir koleksiyon var; ona eklenir.")
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
            importError = "Token'lar vault'a yazılamadı, içe aktarma yapılmadı: \(error.localizedDescription)"
        }
    }
}
