import SwiftUI
import Dev2KitCore

/// İçe aktarma metni (cURL, OpenAPI, Kibana JSON) editörü: `CodeEditor`
/// sınırlarla (`EditorLimits`). Sunucuların döndüğü OpenAPI dokümanı
/// çoğunlukla sıkıştırılmış, tek satırdır: 1 MB'tan uzun satır reddedilmez,
/// metin saklanır ve içe aktarmada kullanılır; editör yerine kısa uyarı
/// (editörler alçak, Workbench'in büyük uyarısı sığmaz).
struct ImportTextEditor: View {
    @Binding var text: String
    let language: CodeLanguage
    var maxBytes: Int = InputLimits.maxImportBytes
    var maxLines: Int = InputLimits.maxImportLines

    @State private var notice: String?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isHiddenFromEditor {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text("Metin editörde gösterilmiyor (\(TextStats.size(text.utf8.count)); \(TextStats.size(WorkbenchLimits.maxEditorLineBytes))'tan uzun satır var — sıkıştırılmış veri tek satırdır). İçe aktarmada olduğu gibi kullanılır.")
                        .font(.secondaryText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Temizle") { text = "" }.controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                CodeEditor(text: $text, language: language, limits: EditorLimits(
                    maxBytes: maxBytes,
                    maxLines: maxLines,
                    maxDisplayBytes: maxBytes,
                    onRejected: { show($0.turkish) },
                    onLongLine: { text = $0 }
                ))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let notice {
                Text(notice)
                    .font(.tinyText)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.down, in: Capsule())
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 1 MB'ın altında taranmaz: her render'da yapılıyor.
    private var isHiddenFromEditor: Bool {
        text.utf8.count > WorkbenchLimits.maxEditorLineBytes && WorkbenchLimits.isTooLargeForEditor(text, maxBytes: maxBytes)
    }

    private func show(_ message: String) {
        notice = message
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}
