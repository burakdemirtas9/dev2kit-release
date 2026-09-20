import SwiftUI
import Dev2KitCore

/// Gönderilmiş isteklerin kaydı: filtreleme, inceleme, geri yükleme.
struct HistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var onlySelectedRequest = false
    @State private var statusFilter: StatusFilter = .all
    @State private var selectedEntryID: UUID?
    @State private var showingSettings = false
    @State private var notice: String?

    private enum StatusFilter: String, CaseIterable {
        case all = "Hepsi"
        case success = "Başarılı"
        case failure = "Hatalı"
    }

    private var filtered: [HistoryEntry] {
        appState.history.filter { entry in
            if onlySelectedRequest, entry.requestID != appState.selectedRequestID { return false }
            switch statusFilter {
            case .all: break
            case .success: if !entry.outcome.isSuccess { return false }
            case .failure: if entry.outcome.isSuccess { return false }
            }
            guard !searchText.isEmpty else { return true }
            return entry.requestName.localizedCaseInsensitiveContains(searchText)
                || entry.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedEntry: HistoryEntry? {
        appState.history.first { $0.id == selectedEntryID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            filters
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.up)
            }

            HSplitView {
                list.frame(minWidth: 300, idealWidth: 380)
                detail.frame(minWidth: 280)
            }
            .frame(minHeight: 320)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            footer
        }
        .padding(20)
        .frame(width: 860, height: 560)
        .onAppear {
            appState.reloadHistory()
            selectedEntryID = appState.history.first?.id
        }
        .sheet(isPresented: $showingSettings) {
            HistorySettingsView()
        }
    }

    private var header: some View {
        HStack {
            Text("Geçmiş")
                .font(.title2).bold()
            Text("\(appState.history.count) kayıt · \(ByteCountFormatter.string(fromByteCount: Int64(appState.historyFileSize), countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !appState.historySettings.isEnabled {
                Label("Kayıt kapalı", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            Button {
                showingSettings = true
            } label: {
                Label("Ayarlar", systemImage: "gearshape")
            }
        }
    }

    private var filters: some View {
        HStack {
            TextField("Ara: istek adı veya adres", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Picker("", selection: $statusFilter) {
                ForEach(StatusFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle("Sadece seçili istek", isOn: $onlySelectedRequest)
                .toggleStyle(.checkbox)
                .disabled(appState.selectedRequestID == nil)
            Spacer()
        }
    }

    private var list: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView(
                    appState.history.isEmpty ? "Henüz kayıt yok" : "Eşleşen kayıt yok",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(appState.history.isEmpty
                        ? "Gönderdiğin istekler burada birikir."
                        : "Filtreleri gevşetmeyi dene.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, selection: $selectedEntryID) { entry in
                    row(entry).tag(entry.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                appState.deleteHistoryEntry(entry.id)
                            } label: {
                                Label("Bu Kaydı Sil", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                statusBadge(entry)
                Text(entry.method.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(entry.requestName)
                    .lineLimit(1)
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(entry.url)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ entry: HistoryEntry) -> some View {
        Group {
            switch entry.outcome {
            case .completed(let status, _, _, _):
                Text("\(status)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(entry.outcome.isSuccess ? Theme.up : (status < 500 ? Theme.warning : Theme.down))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.down)
            }
        }
        .frame(width: 32, alignment: .leading)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.requestName).font(.headline)
                    metadata(entry)
                    Divider()
                    snapshotSummary(entry.snapshot)
                    if let preview = entry.responsePreview {
                        Divider()
                        Text("Yanıt önizlemesi").font(.subheadline).bold()
                        Text(preview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    restoreButtons(entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "Kayıt seç",
                systemImage: "sidebar.right",
                description: Text("Soldan bir kayda tıkla.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metadata(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label("Zaman", entry.date.formatted(date: .abbreviated, time: .standard))
            if let collection = entry.collectionName { label("Koleksiyon", collection) }
            label("Environment", entry.environmentName ?? "yok")
            switch entry.outcome {
            case .completed(let status, let duration, let bytes, let redirects):
                label("Durum", "\(status)")
                label("Süre", String(format: "%.0f ms", duration * 1000))
                label("Boyut", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary))
                if redirects > 0 { label("Yönlendirme", "\(redirects) adım") }
            case .failed(let message):
                label("Hata", message)
            }
        }
    }

    private func snapshotSummary(_ snapshot: RequestModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("İstek").font(.subheadline).bold()
            Text("\(snapshot.method.rawValue) \(snapshot.url)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            ForEach(snapshot.headers) { header in
                Text("\(header.key): \(header.value)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if case .raw(let content, _) = snapshot.body, !content.isEmpty {
                Text(content)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
            }
            Label("Kimlik bilgileri \(HistoryRedactor.mask) ile maskelenir; geri yüklemede mevcut değerler korunur.",
                  systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private func restoreButtons(_ entry: HistoryEntry) -> some View {
        HStack {
            Button {
                if appState.restore(entry) {
                    notice = "İstek bu kayda geri yüklendi."
                } else {
                    notice = "Özgün istek silinmiş; \"Yeni istek olarak ekle\" kullanılabilir."
                }
            } label: {
                Label("Bu Hale Geri Yükle", systemImage: "arrow.uturn.backward")
            }
            .disabled(entry.requestID == nil)

            Menu {
                ForEach(appState.workspace.collections) { collection in
                    Button(collection.name) {
                        appState.restoreAsNewRequest(entry, to: collection.id)
                        notice = "\"\(collection.name)\" içine yeni istek eklendi."
                    }
                }
            } label: {
                Label("Yeni İstek Olarak Ekle", systemImage: "plus.square.on.square")
            }
            .fixedSize()
        }
    }

    private func label(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("Tüm Geçmişi Sil", role: .destructive) {
                    appState.clearHistory()
                    selectedEntryID = nil
                    notice = "Geçmiş temizlendi."
                }
                if let environment = appState.activeEnvironment?.name {
                    Button("Sadece \"\(environment)\" Kayıtlarını Sil", role: .destructive) {
                        appState.clearHistory(environmentName: environment)
                        notice = "\"\(environment)\" kayıtları silindi."
                    }
                }
            } label: {
                Label("Temizle", systemImage: "trash")
            }
            .fixedSize()
            .disabled(appState.history.isEmpty)

            Spacer()
            Button("Kapat") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// Geçmiş davranışının ayarları.
struct HistorySettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle("Geçmişi tut", isOn: $state.historySettings.isEnabled)
                } footer: {
                    Text("Kapalıyken hiçbir gönderim kaydedilmez. Mevcut kayıtlar silinmez.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Stepper(
                        "En fazla \(appState.historySettings.retentionCount) kayıt",
                        value: $state.historySettings.retentionCount,
                        in: 10...2000,
                        step: 10
                    )
                    Stepper(
                        "\(appState.historySettings.retentionDays) günden eskisini sil",
                        value: $state.historySettings.retentionDays,
                        in: 1...365
                    )
                    Stepper(
                        "Dosya en fazla \(appState.historySettings.maxTotalBytes / 1_048_576) MB",
                        value: $state.historySettings.maxTotalBytes,
                        in: 1_048_576...(512 * 1_048_576),
                        step: 1_048_576
                    )
                    Stepper(
                        "İstek gövdesi en fazla \(appState.historySettings.maxSnapshotBodyBytes / 1024) KB",
                        value: $state.historySettings.maxSnapshotBodyBytes,
                        in: 1024...1_048_576,
                        step: 8192
                    )
                } header: {
                    Text("Saklama")
                } footer: {
                    Text("Üç sınır birlikte çalışır; hangisi önce dolarsa en eski kayıtlar düşer. Gövde sınırı tek bir büyük isteğin dosyayı şişirmesini engeller — kırpılan gövdenin başı saklanır.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Yanıt gövdelerini sakla", isOn: $state.historySettings.storeResponseBodies)
                } footer: {
                    Label(
                        "Yanıtlar token ve kişisel veri içerebilir. Saklanırsa bilinen kimlik alanları maskelenir ve boyut sınırlanır, ama yine de riski artırır.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                }

                Section {
                    Label(
                        "Kayıtlar AES-GCM ile şifrelenmiş dosyada tutulur; isteğin şablon hali saklanır, çözülmüş secret değerleri asla yazılmaz.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Kapat") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 460)
    }
}
