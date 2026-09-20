import SwiftUI
import Dev2KitCore

/// `{{` yazıldığında environment değişkenlerini ve `secret:isim` girdilerini
/// öneren metin alanı. Öneriler alanın hemen altında satır içi listelenir
/// (popover odak çaldığı için kullanılmadı); tıklanınca `{{öneri}}` tamamlanır.
struct TemplateTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)?

    @Environment(AppState.self) private var appState
    @FocusState private var isFocused: Bool

    /// Son `{{`'den sonra henüz `}}` ile kapanmamış kısım; öneri tetiği.
    private var pendingToken: String? {
        guard let range = text.range(of: "{{", options: .backwards) else { return nil }
        let after = text[range.upperBound...]
        guard !after.contains("}}") else { return nil }
        return String(after)
    }

    private var suggestions: [String] {
        // Yalnızca odaktaki alanda öner: aksi halde başka alana geçince
        // yarım kalmış {{ yüzünden liste açık kalıyordu.
        guard isFocused, let token = pendingToken else { return [] }
        return appState.templateSuggestions(matching: token)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .focused($isFocused)
                .onSubmit { onSubmit?() }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            complete(with: suggestion)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: suggestion.hasPrefix("secret:") ? "key.fill" : "curlybraces")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.purple)
                                Text(suggestion)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Theme.editorBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.purple.opacity(0.4))
                )
            }
        }
    }

    private func complete(with suggestion: String) {
        guard let range = text.range(of: "{{", options: .backwards) else { return }
        text = String(text[..<range.upperBound]) + suggestion + "}}"
    }
}
