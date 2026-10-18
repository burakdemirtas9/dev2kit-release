import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Dev2KitCore

/// Otomatik içe aktarma (Postman'deki gibi): üstte metin yapıştırma, altta
/// dosya. Ne olduğu içerikten anlaşılır (`AutoImport`); dosya önce doğrulanır
/// (`ImportFile`). Bir metin ya da belge birden çok tür içerebilir: cURL
/// istekleri, koleksiyonlar, Kibana kayıtları, OpenAPI.
///
/// Bulunan istekler koleksiyon içe aktarmasıyla aynı güvenlik incelemesinden
/// geçer. OpenAPI ve Kibana kendi ekranlarında açılır (sunucu adresi, ortam
/// denetimi gibi seçimler orada).
struct AutoImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Hazırlanan koleksiyonlar: çağıran bu ekran kapandıktan sonra ekler/incelemeye gönderir.
    let onPrepared: ([AppState.PreparedImport]) -> Void
    let onOpenOpenAPI: (String) -> Void
    let onOpenKibana: (String) -> Void

    @State private var text = ""
    /// Seçilen dosya: metni editöre konmaz (büyük olabilir), burada tutulur.
    @State private var file: (name: String, kind: ImportFile.Kind, text: String)?
    @State private var findings: AutoImport.Findings?
    @State private var selectedCurl: Set<Int> = []
    @State private var selectedCollections: Set<Int> = []
    @State private var error: String?
    @State private var isWorking = false
    @State private var isTargeted = false
    @State private var showingFilePicker = false
    @State private var generation = 0

    private static let fileTypes: [UTType] = [.pdf, .json, .plainText, .text]
        + ["docx", "xlsx", "md", "sh"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Otomatik İçe Aktar").font(.title2).bold()
            Text("Ne yapıştırırsan ya da hangi dosyayı verirsen içeriğinden tanınır: cURL komutları, Postman ya da dev2kit koleksiyonu, Kibana kaydı, OpenAPI JSON'u. Word, Excel ve PDF belgelerinin içindekiler de bulunur.")
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ImportTextEditor(text: $text, language: .plain)
                .frame(height: 150)
                .background(Theme.editorBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        // verbatim: yoksa SwiftUI adresi tıklanabilir bağlantıya çeviriyor.
                        Text(verbatim: "curl -X POST 'https://api.example.com/v1/orders' \\\n  -H 'Content-Type: application/json'\n\nya da Postman / dev2kit koleksiyonu, OpenAPI JSON'u")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: text) {
                    guard !text.isEmpty || file == nil else { return }
                    file = nil
                    detect(text)
                }

            dropZone
            result
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 640, height: 640)
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: Self.fileTypes) { picked in
            if case .success(let url) = picked { load(url) }
        }
    }

    // MARK: Dosya

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.title2)
                .foregroundStyle(isTargeted ? Theme.accent : .secondary)
            HStack(spacing: 4) {
                Text("Dosyayı buraya bırak ya da")
                Button("Dosya Seç…") { showingFilePicker = true }
                    .buttonStyle(.link)
            }
            .font(.callout)
            Text("PDF, Word (.docx), Excel (.xlsx), JSON ya da metin · en çok \(ImportFile.maxSizeText)")
                .font(.secondaryText)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(isTargeted ? Theme.accent.opacity(0.08) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Theme.accent : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { load(url) } }
            }
            return true
        }
    }

    private func load(_ url: URL) {
        error = nil
        findings = nil
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Boyut OKUMADAN önce: 20 MB'tan büyük dosya belleğe hiç alınmaz.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ImportFile.maxBytes else {
            error = "\(url.lastPathComponent): dosya çok büyük (\(TextStats.size(size))); en fazla \(ImportFile.maxSizeText)."
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            error = "\(url.lastPathComponent) okunamadı."
            return
        }
        let name = url.lastPathComponent
        isWorking = true
        generation += 1
        let current = generation
        Task {
            let outcome = await BackgroundWork.run { () -> Result<(ImportFile.Kind, String, AutoImport.Findings), ImportFile.Rejection> in
                switch ImportFile.kind(of: data) {
                case .failure(let rejection):
                    return .failure(rejection)
                case .success(let kind):
                    do {
                        let text = kind == .pdf ? try Self.pdfText(data) : try ImportFile.text(of: data, kind: kind)
                        return .success((kind, text, AutoImport.scan(text)))
                    } catch let rejection as ImportFile.Rejection {
                        return .failure(rejection)
                    } catch {
                        return .failure(ImportFile.Rejection(message: error.localizedDescription))
                    }
                }
            }
            guard current == generation else { return }
            isWorking = false
            switch outcome {
            case .failure(let rejection):
                self.error = "\(name): \(rejection.message)"
            case .success(let (kind, extracted, found)):
                text = ""
                file = (name, kind, extracted)
                apply(found)
            }
        }
    }

    nonisolated static func pdfText(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data) else {
            throw ImportFile.Rejection(message: "PDF okunamadı.")
        }
        guard !document.isLocked else {
            throw ImportFile.Rejection(message: "Parola korumalı PDF açılmaz.")
        }
        return document.string ?? ""
    }

    // MARK: Algılama

    private func detect(_ text: String) {
        error = nil
        generation += 1
        let current = generation
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            findings = nil
            return
        }
        isWorking = true
        Task {
            let found = await BackgroundWork.run { AutoImport.scan(text) }
            guard current == generation else { return }
            isWorking = false
            apply(found)
        }
    }

    private func apply(_ found: AutoImport.Findings) {
        findings = found
        selectedCurl = Set(found.curl.map(\.id))
        selectedCollections = Set(found.collections.map(\.id))
    }

    @ViewBuilder
    private var result: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let file {
                Label("\(file.name) · \(Self.title(file.kind))", systemImage: "doc.text")
                    .font(.callout.weight(.semibold))
            }
            if isWorking {
                ProgressView().controlSize(.small)
            }
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let findings {
                if findings.isEmpty, let reason = findings.emptyReason {
                    Text(reason).font(.secondaryText).foregroundStyle(.secondary)
                }
                if !findings.curl.isEmpty { curlList(findings.curl) }
                if !findings.collections.isEmpty { collectionList(findings.collections) }
                if findings.recoveredFromDamagedText {
                    warning("Kibana kaydı bozuk metinden alan alan kurtarıldı (ör. resimden OCR ile çıkarılmış). Değerlerde okuma hatası olabilir (0/O, l/1): özellikle token ve gövdeyi kontrol et.")
                }
                if !findings.truncatedFields.isEmpty {
                    warning("Belgede kesik satırlar var; şu değerler eksik olabilir: \(findings.truncatedFields.joined(separator: ", ")).")
                }
                if !findings.kibanaDocuments.isEmpty {
                    found("\(findings.kibanaDocuments.count) Kibana kaydı bulundu: ortam denetimi ve başlık seçimi Kibana ekranında yapılır.")
                }
                if findings.openAPI != nil {
                    found("OpenAPI dokümanı bulundu: sunucu adresi ve grup seçimi OpenAPI ekranında yapılır.")
                }
            }
        }
    }

    private func warning(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.secondaryText)
            .foregroundStyle(Theme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func found(_ message: String) -> some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.secondaryText)
            .foregroundStyle(Theme.up)
    }

    private func curlList(_ findings: [AutoImport.CurlFinding]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                found("\(findings.count) cURL komutu bulundu" + (findings.count == AutoImport.maxCurlCommands ? " (ilk \(AutoImport.maxCurlCommands))" : "") + ".")
                Spacer()
                Button(selectedCurl.count == findings.count ? "Hiçbirini Seçme" : "Tümünü Seç") {
                    selectedCurl = selectedCurl.count == findings.count ? [] : Set(findings.map(\.id))
                }
                .buttonStyle(.link)
                .font(.secondaryText)
            }
            List(findings) { finding in
                Toggle(isOn: Binding(
                    get: { selectedCurl.contains(finding.id) },
                    set: { if $0 { selectedCurl.insert(finding.id) } else { selectedCurl.remove(finding.id) } }
                )) {
                    HStack(spacing: 6) {
                        Text(finding.request.method.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.color(for: finding.request.method))
                            .frame(width: 52, alignment: .leading)
                        Text(finding.request.url)
                            .font(.secondaryMono)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !finding.warnings.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                                .help(finding.warnings.joined(separator: "\n"))
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 70, maxHeight: 150)
        }
    }

    private func collectionList(_ collections: [AutoImport.CollectionFinding]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            found("\(collections.count) koleksiyon bulundu.")
            ForEach(collections) { collection in
                Toggle(isOn: Binding(
                    get: { selectedCollections.contains(collection.id) },
                    set: { if $0 { selectedCollections.insert(collection.id) } else { selectedCollections.remove(collection.id) } }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(Theme.purple)
                        Text(collection.name).lineLimit(1)
                        Text(collection.kind == .postman ? "Postman · script'ler aktarılmaz" : "dev2kit")
                            .font(.secondaryText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Alt çubuk

    private var footer: some View {
        HStack {
            if let json = findings?.kibanaJSON {
                Button("Kibana Ekranında Aç") {
                    dismiss()
                    onOpenKibana(json)
                }
            }
            if let json = findings?.openAPI {
                Button("OpenAPI Ekranında Aç") {
                    dismiss()
                    onOpenOpenAPI(json)
                }
            }
            Spacer()
            Button("Vazgeç") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(importTitle) { performImport() }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || importCount == 0)
        }
    }

    private var importCount: Int { selectedCurl.count + selectedCollections.count }

    private var importTitle: String {
        guard importCount > 0 else { return "İçe Aktar" }
        var parts: [String] = []
        if !selectedCurl.isEmpty { parts.append("\(selectedCurl.count) istek") }
        if !selectedCollections.isEmpty { parts.append("\(selectedCollections.count) koleksiyon") }
        return "İçe Aktar (\(parts.joined(separator: ", ")))"
    }

    /// Seçilen cURL istekleri tek koleksiyon, seçilen koleksiyonlar ayrı ayrı;
    /// hepsi aynı güvenlik incelemesinden birlikte geçer.
    private func performImport() {
        guard let findings else { return }
        var prepared: [AppState.PreparedImport] = []
        let chosenCurl = findings.curl.filter { selectedCurl.contains($0.id) }
        if !chosenCurl.isEmpty {
            let warnings = chosenCurl.flatMap { finding in finding.warnings.map { "\(finding.request.name): \($0)" } }
            let base = file.map { ($0.name as NSString).deletingPathExtension } ?? "Otomatik İçe Aktarma"
            prepared.append(appState.prepareCollectionImport(name: base, requests: chosenCurl.map(\.request), notes: warnings))
        }
        for collection in findings.collections where selectedCollections.contains(collection.id) {
            let reserved = prepared.map(\.review.collection.name)
            switch appState.prepareImport(collection.data, source: collection.kind == .postman ? .postman : .dev2kit, reservedNames: reserved) {
            case .success(let item): prepared.append(item)
            case .failure(let failure):
                error = "\(collection.name): \(failure.message)"
                return
            }
        }
        dismiss()
        onPrepared(prepared)
    }

    private static func title(_ kind: ImportFile.Kind) -> String {
        switch kind {
        case .pdf: return "PDF"
        case .word: return "Word"
        case .excel: return "Excel"
        case .text: return "Metin"
        }
    }
}
