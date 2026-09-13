import AppKit
import SwiftUI
import BoltDockCore

/// Panodan yapıştırılan curl komutundan istek oluşturur.
/// Komut yazıldıkça canlı çözümlenir; ne üretileceği içe aktarmadan önce görünür.
struct CurlImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var command = ""
    @State private var name = "cURL İsteği"
    @State private var targetCollectionID: UUID?
    @State private var preview: CurlImporter.Result?
    @State private var parseError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("cURL'den İstek")
                .font(.title2).bold()
            Text("Tarayıcının \"Copy as cURL\" çıktısını ya da dokümandaki örneği yapıştır.")
                .font(.caption)
                .foregroundStyle(.secondary)

            CodeEditor(text: $command, language: .plain)
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
                    command = NSPasteboard.general.string(forType: .string) ?? ""
                } label: {
                    Label("Panodan Yapıştır", systemImage: "doc.on.clipboard")
                }
                Spacer()
                TextField("İstek adı", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onChange(of: name) { reparse() }
            }

            if let parseError {
                Label(parseError, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.down)
                    .lineLimit(2)
            }

            if let preview {
                summary(preview)
            }

            Divider()

            HStack {
                Picker("Ekle:", selection: $targetCollectionID) {
                    ForEach(appState.workspace.collections) { collection in
                        Text(collection.name).tag(UUID?.some(collection.id))
                    }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button("Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("İçe Aktar") { performImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || targetCollectionID == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .onAppear {
            targetCollectionID = appState.workspace.collections.first?.id
        }
    }

    private func summary(_ result: CurlImporter.Result) -> some View {
        let request = result.request
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(request.method.rawValue)
                        .font(.system(.caption, design: .monospaced)).bold()
                        .foregroundStyle(Theme.purple)
                    Text(request.url)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                }
                Text(details(request))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
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
        var parts = ["\(request.headers.count) başlık"]
        if !request.queryParams.isEmpty { parts.append("\(request.queryParams.count) query") }
        switch request.body {
        case .none: break
        case .raw(_, let contentType): parts.append("raw gövde (\(contentType))")
        case .formURLEncoded(let fields): parts.append("urlencoded, \(fields.count) alan")
        case .multipartForm(let fields): parts.append("form-data, \(fields.count) alan")
        }
        if request.auth != .none { parts.append("auth: \(request.auth.displayName)") }
        return parts.joined(separator: " · ")
    }

    private func reparse() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            preview = nil
            parseError = nil
            return
        }
        do {
            preview = try CurlImporter.parse(trimmed, name: name.isEmpty ? "cURL İsteği" : name)
            parseError = nil
        } catch {
            preview = nil
            parseError = error.localizedDescription
        }
    }

    private func performImport() {
        guard let preview, let targetCollectionID else { return }
        appState.addImportedRequest(preview.request, to: targetCollectionID)
        dismiss()
    }
}
