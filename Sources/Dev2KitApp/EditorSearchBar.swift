import SwiftUI
import Dev2KitCore

/// Editörün üstündeki arama çubuğu.
///
/// Gövde ve yanıt editörlerinin her birinin kendi çubuğu ve kendi
/// `EditorSearchController`'ı vardır; ikisi birbirini etkilemez. Ortak olan
/// kural `TextSearch`'te, gösterim burada.
struct EditorSearchBar: View {
    @ObservedObject var search: EditorSearchController
    /// Çubuk açılınca yazı imleci doğrudan kutuya girsin.
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Ara", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit { search.submit() }

            status

            navigationButtons

            Divider().frame(height: 14)

            toggle(
                "Aa",
                isOn: search.options.caseSensitive,
                help: "Büyük/küçük harfe duyarlı"
            ) { search.options.caseSensitive.toggle() }

            toggle(
                ".*",
                isOn: search.options.isRegex,
                help: "Düzenli ifade — ⏎ ile çalışır"
            ) { search.options.isRegex.toggle() }

            Button {
                search.close()
            } label: {
                Image(systemName: "xmark")
                    .iconHitTarget(20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Aramayı kapat")
            .accessibilityLabel("Aramayı kapat")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { focused = true }
        .onChange(of: search.focusRequest) { focused = true }
    }

    /// "3/17" ya da sorun varsa sebebi. Sayının hemen yanında durması gerekiyor:
    /// kullanıcı yazarken bakacağı tek yer burası.
    @ViewBuilder
    private var status: some View {
        if search.isInvalidPattern {
            Text("geçersiz kalıp")
                .foregroundStyle(Theme.down)
        } else if search.query.isEmpty {
            EmptyView()
        } else if search.matchCount == 0 {
            Text(search.runsIncrementally ? "sonuç yok" : "⏎ ile ara")
                .foregroundStyle(.secondary)
        } else {
            Text(counter)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                // Sayı değişince çubuktaki düğmeler sağa sola oynamasın.
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    /// Üst sınıra takıldıysa "2000+" yazılır: eksik listeyi tam sanmasın.
    private var counter: String {
        let position = (search.currentIndex ?? 0) + 1
        let total = search.isTruncated ? "\(search.matchCount)+" : "\(search.matchCount)"
        return "\(position)/\(total)"
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button {
                search.previous()
            } label: {
                Image(systemName: "chevron.up").iconHitTarget(20)
            }
            .help("Önceki eşleşme")
            .accessibilityLabel("Önceki eşleşme")

            Button {
                search.next()
            } label: {
                Image(systemName: "chevron.down").iconHitTarget(20)
            }
            .help("Sonraki eşleşme")
            .accessibilityLabel("Sonraki eşleşme")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(search.matchCount == 0)
    }

    private func toggle(
        _ title: String,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .iconHitTarget(20)
                .background(
                    isOn ? Theme.accent.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Theme.accent : .secondary)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Arama çubuğunu açıp kapatan düğme. Araç çubuğunda `FoldButtons`'ın yanında.
struct SearchToggleButton: View {
    @ObservedObject var search: EditorSearchController

    var body: some View {
        Button {
            search.toggle()
        } label: {
            Image(systemName: "magnifyingglass")
                .iconHitTarget(20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(search.isPresented ? Theme.accent : .secondary)
        .help("Metinde ara")
        .accessibilityLabel("Metinde ara")
    }
}
