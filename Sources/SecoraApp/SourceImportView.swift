import SwiftUI
import UniformTypeIdentifiers
import SecoraCore

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
            Text("Kaynak Koddan Giden İstekler")
                .font(.title2).bold()
            Text("Spring Boot projesinin klasörünü seç. Servisin dışarıya attığı istekler (Feign, HTTP Interface, RestTemplate, WebClient, RestClient) koleksiyona çevrilir. Kod yalnızca okunur: derlenmez, çalıştırılmaz, internete çıkılmaz. src/test, target ve build atlanır.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("Proje Klasörü Seç…", systemImage: "folder")
                }
                .disabled(scanning)
                if scanning {
                    ProgressView().controlSize(.small)
                    Text("Taranıyor…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.caption)
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
                Button("Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Devam") { prepare() }
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
                onConfirm: { finish(pending.items) },
                onCancel: { pendingReview = nil }
            )
        }
    }

    @ViewBuilder
    private func summary(_ result: OutboundScanResult) -> some View {
        let counts = OutboundCall.Source.allCases.compactMap { source -> String? in
            let count = result.calls.filter { $0.source == source }.count
            return count > 0 ? "\(count) \(source.rawValue)" : nil
        }
        let incomplete = result.calls.filter { !$0.isComplete }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(result.projectName).font(.headline)
                Text("\(result.javaFileCount) Java dosyası").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(counts.isEmpty ? "giden istek bulunamadı" : counts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if incomplete > 0 {
                Label("\(incomplete) isteğin adresi tam çözülemedi; \"(eksik)\" işaretli gelir, yerleri inceleme ekranında listelenir.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }

            HStack {
                Picker("Profil:", selection: $profile) {
                    Text("Varsayılan").tag("")
                    ForEach(result.config.profiles, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 240)
                Text("Adresler bu profilin ayarlarından doldurulur.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Dış servis adresleri") {
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
                Toggle("Değeri bulunan adresleri \"\(environment.name)\" environment'ına ekle (var olanlar değişmez)", isOn: $addVariables)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            } else {
                Label("Aktif environment yok; adres değişkenlerini bir environment'a elle ekle.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }

            GroupBox("İstekler (\(result.calls.count))") {
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
                                    Text("eksik").font(.caption2.bold()).foregroundStyle(Theme.warning)
                                }
                                Spacer()
                                Text(call.location)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .font(.caption)
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
                .font(.system(.caption, design: .monospaced))
                .frame(width: 220, alignment: .leading)
            switch variable.status {
            case .value(let value):
                Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            case .sensitive:
                Label("kimlik bilgisi içeriyor, kopyalanmadı", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            case .missing(let reason):
                Text("boş — \(reason)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(variable.origin).font(.caption2).foregroundStyle(.tertiary)
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
                    errorMessage = "Projede dışarıya giden istek bulunamadı."
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
