import SwiftUI
import UniformTypeIdentifiers
import Dev2KitCore

/// Bir Spring Boot projesinin kaynak kodundan servisin dışarıya attığı
/// istekleri (Feign, HTTP Interface, RestTemplate, WebClient, RestClient)
/// koleksiyona çevirir. Kod yalnızca okunur.
struct SourceImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var showingFolderPicker = false
    @State private var scanning = false
    @State private var errorMessage: String?
    @State private var result: OutboundScanResult?
    @State private var profile = ""
    @State private var addVariables = true
    @State private var pendingReview: AppState.PendingImport?

    private var variables: [OutboundCollectionBuilder.Variable] {
        result.map { OutboundCollectionBuilder.variables(for: $0, profile: profile.isEmpty ? nil : profile) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("source.title"))
                .font(.title2).bold()
            Text(L10n.t("source.subtitle"))
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label(L10n.t("source.chooseFolder"), systemImage: "folder")
                }
                .disabled(scanning)
                if scanning {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("source.scanning")).font(.secondaryText).foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
            }

            if let result {
                summary(result)
            } else {
                Spacer()
            }

            Divider()
            HStack {
                Spacer()
                Button(L10n.t("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("common.continue")) { prepare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(result?.calls.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(width: 680, height: 640)
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { picked in
            guard case .success(let url) = picked else { return }
            scan(url)
        }
        .sheet(item: $pendingReview) { pending in
            ImportReviewView(
                items: pending.items,
                onConfirm: { finish($0) },
                onCancel: { pendingReview = nil }
            )
        }
    }

    @ViewBuilder
    private func summary(_ result: OutboundScanResult) -> some View {
        let counts = OutboundCall.Source.allCases.compactMap { source -> String? in
            let count = result.calls.filter { $0.source == source }.count
            return count > 0 ? "\(L10n.number(count)) \(source.rawValue)" : nil
        }
        let incomplete = result.calls.filter { !$0.isComplete }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(result.projectName).font(.headline)
                Text(L10n.plural("source.javaFiles", count: result.javaFileCount)).font(.secondaryText).foregroundStyle(.secondary)
                Spacer()
                Text(counts.isEmpty ? L10n.t("source.noneFound.short") : counts.joined(separator: " · "))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
            if incomplete > 0 {
                Label(L10n.plural("source.incomplete", count: incomplete),
                      systemImage: "exclamationmark.triangle")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            }

            HStack {
                Picker(L10n.t("source.profile"), selection: $profile) {
                    Text(L10n.t("source.profile.default")).tag("")
                    ForEach(result.config.profiles, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 240)
                Text(L10n.t("source.profile.help"))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }

            GroupBox(L10n.t("source.externalURLs")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(variables) { variable in
                            variableRow(variable)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }

            if let environment = appState.activeEnvironment {
                Toggle(L10n.t("source.addVariables", environment.name), isOn: $addVariables)
                    .toggleStyle(.checkbox)
                    .font(.secondaryText)
            } else {
                Label(L10n.t("source.noEnvironment"), systemImage: "exclamationmark.triangle")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            }

            GroupBox(L10n.t("source.requests", L10n.number(result.calls.count))) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(result.calls) { call in
                            HStack(spacing: 6) {
                                Text(call.method.rawValue)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.color(for: call.method))
                                    .frame(width: 44, alignment: .leading)
                                Text(OutboundCollectionBuilder.requestName(for: call))
                                    .lineLimit(1)
                                if !call.isComplete {
                                    Text(L10n.t("source.incompleteBadge")).font(.tinyText.bold()).foregroundStyle(Theme.warning)
                                }
                                Spacer()
                                Text(call.location)
                                    .font(.tinyText)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .font(.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func variableRow(_ variable: OutboundCollectionBuilder.Variable) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("{{\(variable.name)}}")
                .font(.secondaryMono)
                .frame(width: 220, alignment: .leading)
            switch variable.status {
            case .value(let value):
                Text(value).font(.secondaryMono).textSelection(.enabled)
            case .sensitive:
                Label(L10n.t("source.sensitive"), systemImage: "lock.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            case .missing(let reason):
                Text(L10n.t("source.emptyReason", reason)).font(.secondaryText).foregroundStyle(.secondary)
            }
            Spacer()
            Text(variable.origin).font(.tinyText).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Akış

    private func scan(_ url: URL) {
        scanning = true
        errorMessage = nil
        result = nil
        Task {
            do {
                let scanned = try await appState.scanOutbound(url)
                result = scanned
                profile = ""
                if scanned.calls.isEmpty {
                    errorMessage = L10n.t("source.noneFound")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            scanning = false
        }
    }

    private func prepare() {
        guard let result else { return }
        switch appState.prepareOutboundImport(result, variables: variables) {
        case .success(let prepared):
            pendingReview = AppState.PendingImport(items: [prepared])
        case .failure(let failure):
            errorMessage = failure.message
        }
    }

    private func finish(_ items: [AppState.PreparedImport]) {
        pendingReview = nil
        if addVariables {
            for variable in variables {
                if let value = variable.value {
                    appState.addVariableToActiveEnvironmentIfMissing(variable.name, value: value)
                }
            }
        }
        appState.portingMessage = appState.commitImport(items)
        dismiss()
    }
}
