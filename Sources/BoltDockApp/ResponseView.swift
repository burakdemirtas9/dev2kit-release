import SwiftUI
import BoltDockCore

struct ResponseView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: Tab = .body

    enum Tab: String, CaseIterable {
        case body = "Body"
        case headers = "Headers"
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
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
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
                }
            }
        }
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
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

}
