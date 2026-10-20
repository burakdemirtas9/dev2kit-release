import AppKit
import SwiftUI
import Dev2KitCore

/// Panodan yapıştırılan curl komutundan istek oluşturur.
/// Komut yazıldıkça canlı çözümlenir; ne üretileceği içe aktarmadan önce görünür.
struct CurlImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var command = ""
    @State private var name = L10n.t("curl.defaultName")
    @State private var targetCollectionID: UUID?
    @State private var preview: CurlImporter.Result?
    @State private var parseError: String?
    /// Önizlenen isteğin güvenlik bulguları; kesin engel varsa aktarılmaz.
    @State private var findings: [ImportFinding] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("curl.import.title"))
                .font(.title2).bold()
            Text(L10n.t("curl.import.subtitle"))
                .font(.secondaryText)
                .foregroundStyle(.secondary)

            // cURL komutu bir istek: girdi sınırları (4 MB, 16.000 satır).
            ImportTextEditor(text: $command, language: .plain,
                             maxBytes: WorkbenchLimits.maxInputBytes, maxLines: WorkbenchLimits.maxInputLines)
                .frame(height: 150)
                .background(Theme.editorBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if command.isEmpty {
                        Text("curl 'https://api.example.com/v1/items' \\\n  -H 'accept: application/json'")
                            .foregroundStyle(.tertiary)
                            .font(.system(.body, design: .monospaced))
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: command) { reparse() }

            HStack {
                Button {
                    let pasted = NSPasteboard.general.string(forType: .string) ?? ""
                    if let rejection = InputLimits.rejection(of: pasted, maxBytes: WorkbenchLimits.maxInputBytes, maxLines: WorkbenchLimits.maxInputLines) {
                        parseError = rejection
                    } else {
                        command = pasted
                    }
                } label: {
                    Label(L10n.t("openapi.paste"), systemImage: "doc.on.clipboard")
                }
                Spacer()
                TextField(L10n.t("request.name.placeholder"), text: $name)
                    .inputLimit(.name)
                    .textFieldStyle(.input)
                    .frame(width: 200)
                    .onChange(of: name) { reparse() }
            }

            if let parseError {
                Label(parseError, systemImage: "xmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .lineLimit(2)
            }

            if let preview {
                summary(preview)
            }

            Divider()

            HStack {
                Picker(L10n.t("import.addTo"), selection: $targetCollectionID) {
                    ForEach(appState.workspace.collections.filter { !$0.isTokenFactory }) { collection in
                        Text(collection.displayName).tag(UUID?.some(collection.id))
                    }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button(L10n.t("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("import.menu.title")) { performImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || targetCollectionID == nil || findings.contains { $0.severity == .block })
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .onAppear {
            // Varsayılan davranış korunur: kullanıcının ilk koleksiyonu (Koleksiyonsuz kabı en üstte durur).
            targetCollectionID = appState.workspace.regularCollections.first?.id ?? appState.workspace.collections.first?.id
        }
    }

    private func summary(_ result: CurlImporter.Result) -> some View {
        let request = result.request
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(request.method.rawValue)
                        .font(.secondaryMono).bold()
                        .foregroundStyle(Theme.purple)
                    Text(request.url)
                        .font(.secondaryMono)
                        .lineLimit(2)
                }
                Text(details(request))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                ForEach(findings, id: \.self) { finding in
                    Label("\(finding.title): \(finding.detail)", systemImage: finding.severity == .block ? "xmark.octagon.fill" : "exclamationmark.shield.fill")
                        .font(.secondaryText)
                        .foregroundStyle(finding.severity == .block ? Theme.down : (finding.severity == .warn ? Theme.warning : .secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.secondaryText)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: 130)
        .background(Theme.editorBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func details(_ request: RequestModel) -> String {
        var parts = [L10n.plural("curl.details.headers", count: request.headers.count)]
        if !request.queryParams.isEmpty { parts.append(L10n.plural("curl.details.query", count: request.queryParams.count)) }
        switch request.body {
        case .none: break
        case .raw(_, let contentType): parts.append(L10n.t("curl.details.raw", contentType))
        case .formURLEncoded(let fields): parts.append(L10n.plural("curl.details.urlencoded", count: fields.count))
        case .multipartForm(let fields): parts.append(L10n.plural("curl.details.formData", count: fields.count))
        }
        if request.auth != .none { parts.append("auth: \(request.auth.displayName)") }
        return parts.joined(separator: " · ")
    }

    private func reparse() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            preview = nil
            parseError = nil
            findings = []
            return
        }
        do {
            preview = try CurlImporter.parse(trimmed, name: name.isEmpty ? L10n.t("curl.defaultName") : name)
            parseError = nil
            findings = preview.map { ImportReviewer.review($0.request, context: appState.importContext) } ?? []
        } catch {
            preview = nil
            parseError = error.localizedDescription
            findings = []
        }
    }

    private func performImport() {
        guard let preview, let targetCollectionID else { return }
        appState.addImportedRequest(preview.request, to: targetCollectionID)
        dismiss()
    }
}
