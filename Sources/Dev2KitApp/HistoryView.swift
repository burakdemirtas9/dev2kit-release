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

        var title: String {
            switch self {
            case .all: return L10n.t("history.filter.all")
            case .success: return L10n.t("history.filter.success")
            case .failure: return L10n.t("history.filter.failure")
            }
        }
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

    /// Seçili kaydın tamamı (yanıt önizlemesi, istek gövdesi). Liste yalnızca
    /// dizini tutar; içerik seçilince arka planda okunur.
    @State private var loadedEntry: HistoryEntry?

    private var selectedEntry: HistoryEntry? {
        if let loadedEntry, loadedEntry.id == selectedEntryID { return loadedEntry }
        return appState.history.first { $0.id == selectedEntryID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            filters
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.up)
            }

            // İlk açılışta liste ~380 punto (eski idealWidth).
            SplitPanes(minFirst: 300, minSecond: 280, initialFraction: 380 / 810) {
                list
            } second: {
                detail
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
        .task(id: selectedEntryID) {
            guard let id = selectedEntryID else { loadedEntry = nil; return }
            let entry = await appState.loadHistoryEntry(id)
            if selectedEntryID == id { loadedEntry = entry }
        }
        .sheet(isPresented: $showingSettings) {
            HistorySettingsView()
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.t("toolbar.history"))
                .font(.title2).bold()
            Text(L10n.plural("history.summary", count: appState.history.count, ByteCountFormatter.string(fromByteCount: Int64(appState.historyFileSize), countStyle: .file)))
                .font(.secondaryText)
                .foregroundStyle(.secondary)
            Spacer()
            if !appState.historySettings.isEnabled {
                Label(L10n.t("history.recordingOff"), systemImage: "pause.circle")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            }
            Button {
                showingSettings = true
            } label: {
                Label(L10n.t("history.settings"), systemImage: "gearshape")
            }
        }
    }

    private var filters: some View {
        HStack {
            TextField(L10n.t("history.search.placeholder"), text: $searchText)
                .inputLimit(.search)
                .textFieldStyle(.input)
                .frame(maxWidth: 280)
            Picker("", selection: $statusFilter) {
                ForEach(StatusFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle(L10n.t("history.onlySelected"), isOn: $onlySelectedRequest)
                .toggleStyle(.checkbox)
                .disabled(appState.selectedRequestID == nil)
            Spacer()
        }
    }

    private var list: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView(
                    appState.history.isEmpty ? L10n.t("history.empty.title") : L10n.t("history.noMatch.title"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(appState.history.isEmpty
                        ? L10n.t("history.empty.message")
                        : L10n.t("history.noMatch.message"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, selection: $selectedEntryID) { entry in
                    row(entry).tag(entry.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                appState.deleteHistoryEntry(entry.id)
                            } label: {
                                Label(L10n.t("history.deleteEntry"), systemImage: "trash")
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
                    .font(.tinyText)
                    .foregroundStyle(.tertiary)
            }
            Text(entry.url)
                .font(.secondaryMono)
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
                    .font(.tinyText)
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
                        Text(L10n.t("history.responsePreview")).font(.subheadline).bold()
                        Text(preview)
                            .font(.secondaryMono)
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
                L10n.t("history.select.title"),
                systemImage: "sidebar.right",
                description: Text(L10n.t("history.select.message"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metadata(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label(L10n.t("history.field.time"), entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.language.locale)))
            if let collection = entry.collectionName { label(L10n.t("history.field.collection"), collection) }
            label("Environment", entry.environmentName ?? L10n.t("history.field.none"))
            switch entry.outcome {
            case .completed(let status, let duration, let bytes, let redirects):
                label(L10n.t("history.field.status"), "\(status)")
                label(L10n.t("history.field.duration"), String(format: "%.0f ms", duration * 1000))
                label(L10n.t("history.field.size"), ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary))
                if redirects > 0 { label(L10n.t("response.tab.redirects"), L10n.plural("history.field.steps", count: redirects)) }
            case .failed(let message):
                label(L10n.t("message.kind.error"), message)
            }
        }
    }

    private func snapshotSummary(_ snapshot: RequestModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Request").font(.subheadline).bold()
            Text("\(snapshot.method.rawValue) \(snapshot.url)")
                .font(.secondaryMono)
                .textSelection(.enabled)
            ForEach(snapshot.headers) { header in
                Text("\(header.key): \(header.value)")
                    .font(.tinyMono)
                    .foregroundStyle(.secondary)
            }
            if case .raw(let content, _) = snapshot.body, !content.isEmpty {
                Text(content)
                    .font(.tinyMono)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
            }
            Label(L10n.t("history.masked", HistoryRedactor.mask),
                  systemImage: "lock.shield")
                .font(.tinyText)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private func restoreButtons(_ entry: HistoryEntry) -> some View {
        HStack {
            Button {
                if appState.restore(entry) {
                    notice = L10n.t("history.restored")
                } else {
                    notice = L10n.t("history.originalDeleted")
                }
            } label: {
                Label(L10n.t("history.restore"), systemImage: "arrow.uturn.backward")
            }
            .disabled(entry.requestID == nil)

            Menu {
                ForEach(appState.workspace.collections.filter { !$0.isTokenFactory }) { collection in
                    Button(collection.displayName) {
                        appState.restoreAsNewRequest(entry, to: collection.id)
                        notice = L10n.t("history.addedTo", collection.displayName)
                    }
                }
            } label: {
                Label(L10n.t("history.addAsNew"), systemImage: "plus.square.on.square")
            }
            .fixedSize()
        }
    }

    private func label(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.secondaryText)
                .textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack {
            Menu {
                Button(L10n.t("history.deleteAll"), role: .destructive) {
                    appState.clearHistory()
                    selectedEntryID = nil
                    notice = L10n.t("history.cleared")
                }
                if let environment = appState.activeEnvironment?.name {
                    Button(L10n.t("history.deleteEnvironment", environment), role: .destructive) {
                        appState.clearHistory(environmentName: environment)
                        notice = L10n.t("history.environmentDeleted", environment)
                    }
                }
            } label: {
                Label(L10n.t("common.clear"), systemImage: "trash")
            }
            .fixedSize()
            .disabled(appState.history.isEmpty)

            Spacer()
            Button(L10n.t("common.close")) { dismiss() }
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
                    Toggle(L10n.t("history.keep"), isOn: $state.historySettings.isEnabled)
                } footer: {
                    Text(L10n.t("history.keep.help"))
                        .font(.secondaryText).foregroundStyle(.secondary)
                }

                Section {
                    Stepper(
                        L10n.t("history.retention.count", L10n.number(appState.historySettings.retentionCount)),
                        value: $state.historySettings.retentionCount,
                        in: 10...2000,
                        step: 10
                    )
                    Stepper(
                        L10n.t("history.retention.days", L10n.number(appState.historySettings.retentionDays)),
                        value: $state.historySettings.retentionDays,
                        in: 1...365
                    )
                    Stepper(
                        L10n.t("history.retention.fileSize", L10n.number(appState.historySettings.maxTotalBytes / 1_048_576)),
                        value: $state.historySettings.maxTotalBytes,
                        in: 1_048_576...(512 * 1_048_576),
                        step: 1_048_576
                    )
                    Stepper(
                        L10n.t("history.retention.bodySize", L10n.number(appState.historySettings.maxSnapshotBodyBytes / 1024)),
                        value: $state.historySettings.maxSnapshotBodyBytes,
                        in: 1024...1_048_576,
                        step: 8192
                    )
                } header: {
                    Text(L10n.t("history.retention"))
                } footer: {
                    Text(L10n.t("history.retention.help"))
                        .font(.secondaryText).foregroundStyle(.secondary)
                }

                Section {
                    Toggle(L10n.t("history.storeResponses"), isOn: $state.historySettings.storeResponseBodies)
                } footer: {
                    Label(
                        L10n.t("history.storeResponses.warning"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
                }

                Section {
                    Label(
                        L10n.t("history.encryptionNote"),
                        systemImage: "lock.shield"
                    )
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(L10n.t("common.close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 460)
    }
}
