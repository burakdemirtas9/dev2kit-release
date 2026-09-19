import AppKit
import SwiftUI
import SecoraCore

struct ResponseView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: Tab = .body
    @State private var copied = false
    @State private var fileSaveError: String?

    enum Tab: String, CaseIterable {
        case body = "Body"
        case headers = "Headers"
        case redirects = "Yönlendirme"
    }

    var body: some View {
        switch appState.lastResponse {
        case .idle:
            ContentUnavailableView(
                "Henüz yanıt yok",
                systemImage: "arrow.down.circle",
                description: Text("⌘⏎ ile isteği gönder.")
            )
        case .loading:
            ProgressView("Gönderiliyor…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let message):
            ContentUnavailableView(
                "İstek başarısız",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .success(let display):
            let response = display.data
            VStack(spacing: 0) {
                statusBar(display)
                Divider()
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        if tab == .redirects {
                            // Zincir yoksa sekmeyi hiç gösterme.
                            if !response.redirects.isEmpty || response.redirectStop != nil {
                                Text("\(tab.rawValue) (\(response.redirects.count))").tag(tab)
                            }
                        } else {
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .padding(8)

                switch selectedTab {
                case .body:
                    CodeEditor(
                        text: .constant(display.prettyText),
                        language: display.language,
                        isEditable: false
                    )
                    .background(Theme.editorBackground)
                case .headers:
                    // Aynı başlık birden çok kez gelebilir (Set-Cookie);
                    // id olarak isim kullanmak SwiftUI'da çakışma yaratıyordu.
                    List(Array(response.headers.enumerated()), id: \.offset) { _, header in
                        HStack(alignment: .top) {
                            Text(header.name)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                                .frame(width: 220, alignment: .leading)
                            Text(header.value)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .listStyle(.inset)
                case .redirects:
                    redirectList(response)
                }
            }
            .onChange(of: display.data.finalURL) {
                // Yeni yanıtta zincir yoksa sekme boşta kalmasın.
                if selectedTab == .redirects, response.redirects.isEmpty, response.redirectStop == nil {
                    selectedTab = .body
                }
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
            .alert(
                "Dosyaya kaydedilemedi",
                isPresented: Binding(
                    get: { fileSaveError != nil },
                    set: { if !$0 { fileSaveError = nil } }
                )
            ) {
                Button("Tamam") { fileSaveError = nil }
            } message: {
                Text(fileSaveError ?? "")
            }
        }
    }

    /// Yönlendirme zinciri: her adımda nereye gidildiği ve hangi hassas
    /// başlıkların düşürüldüğü denetim izi olarak gösterilir.
    private func redirectList(_ response: ResponseData) -> some View {
        List {
            ForEach(Array(response.redirects.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                        Text("\(step.statusCode)")
                            .font(.system(.caption, design: .monospaced)).bold()
                            .foregroundStyle(Theme.warning)
                        Text(step.to.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if !step.strippedHeaders.isEmpty {
                        Label(
                            "Farklı host: \(step.strippedHeaders.joined(separator: ", ")) başlıkları düşürüldü",
                            systemImage: "lock.shield.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(Theme.up)
                    }
                }
                .padding(.vertical, 2)
            }
            if let stop = response.redirectStop {
                Label("Zincir kesildi: \(stop.explanation)", systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.down)
            }
            if let final = response.finalURL {
                Label("Son adres: \(final.absoluteString)", systemImage: "flag.checkered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .listStyle(.inset)
    }

    private func statusBar(_ display: AppState.ResponseDisplay) -> some View {
        let response = display.data
        return HStack(spacing: 16) {
            Text("\(response.statusCode)")
                .font(.system(.body, design: .monospaced)).bold()
                .foregroundStyle(response.isSuccess ? Theme.up : (response.statusCode < 500 ? Theme.warning : Theme.down))
            Text(String(format: "%.0f ms", response.duration * 1000))
                .foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(response.body.count), countStyle: .binary))
                .foregroundStyle(.secondary)
            if !response.redirects.isEmpty {
                Label("\(response.redirects.count) yönlendirme", systemImage: "arrow.triangle.turn.up.right.diamond")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            if let stop = response.redirectStop {
                Label(stop.explanation, systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.down)
            }
            Spacer()
            responseActions(display)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Kopyalama ve kaydetme yalnızca kullanıcı düğmeye bastığında olur;
    /// hiçbir yanıt kendiliğinden panoya ya da diske gitmez.
    private func responseActions(_ display: AppState.ResponseDisplay) -> some View {
        let response = display.data
        let isText = !response.body.isEmpty && response.bodyText != nil
        return HStack(spacing: 10) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.prettyText, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Kopyalandı" : "Kopyala",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(!isText)
            .help(isText
                  ? "Görünen gövdeyi panoya kopyalar"
                  : "Gövde boş ya da metin değil; Dosyaya Kaydet ile alabilirsin")

            Button {
                saveBodyToFile(response)
            } label: {
                Label("Dosyaya Kaydet…", systemImage: "square.and.arrow.down")
            }
            .disabled(response.body.isEmpty)
            .help(response.body.isEmpty
                  ? "Gövde boş"
                  : "Sunucudan gelen ham gövdeyi, seçtiğin konuma kaydeder")
        }
        .buttonStyle(.borderless)
    }

    /// Ham byte'lar yazılır (biçimlendirilmiş hali değil): PDF, görsel gibi
    /// ikili yanıtlar bozulmadan kaydedilsin. Konum ve adı kaydetme
    /// penceresinde kullanıcı seçer; Vazgeç derse hiçbir şey yazılmaz.
    private func saveBodyToFile(_ response: ResponseData) {
        let panel = NSSavePanel()
        panel.title = "Yanıtı Dosyaya Kaydet"
        panel.nameFieldStringValue = ResponseFileName.suggested(for: response)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try response.body.write(to: url, options: .atomic)
        } catch {
            fileSaveError = error.localizedDescription
        }
    }

}
