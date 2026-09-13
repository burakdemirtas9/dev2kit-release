import SwiftUI
import BoltDockCore

struct ResponseView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: Tab = .body

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
                statusBar(response)
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

    private func statusBar(_ response: ResponseData) -> some View {
        HStack(spacing: 16) {
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
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

}
