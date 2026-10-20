import SwiftUI
import Dev2KitCore

/// Editörün üstündeki arama çubuğu.
///
/// Gövde ve yanıt editörlerinin her birinin kendi çubuğu ve kendi
/// `EditorSearchController`'ı vardır; ikisi birbirini etkilemez. Ortak olan
/// kural `TextSearch`'te, gösterim burada.
struct EditorSearchBar: View {
    @ObservedObject var search: EditorSearchController
    /// API Client Türkçe, Workbench İngilizce (docs/V2.md); aynı bileşen.
    var strings: SearchStrings { .localized }
    /// Çubuğun bulunduğu mod: gizli moddaki çubuk Esc'i yakalamasın (iki mod
    /// da canlı tutuluyor, bkz. ContentView).
    var mode: AppMode = .apiClient
    /// Çubuk açılınca yazı imleci doğrudan kutuya girsin.
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(strings.prompt, text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit { search.submit() }
                .inputLimit(.search)

            status

            navigationButtons

            Divider().frame(height: 14)

            toggle(
                "Aa",
                isOn: search.options.caseSensitive,
                help: strings.caseSensitive
            ) { search.options.caseSensitive.toggle() }

            toggle(
                ".*",
                isOn: search.options.isRegex,
                help: strings.regex
            ) { search.options.isRegex.toggle() }

            Button {
                search.close()
            } label: {
                Image(systemName: "xmark")
                    .iconHitTarget(20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(KeyboardShortcut(.escape, modifiers: []), onlyIn: mode)
            .help(strings.close)
            .accessibilityLabel(strings.close)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .inputChrome(isFocused: focused)
        .onAppear { focused = true }
        .onChange(of: search.focusRequest) { focused = true }
    }

    /// "3/17" ya da sorun varsa sebebi. Sayının hemen yanında durması gerekiyor:
    /// kullanıcı yazarken bakacağı tek yer burası.
    @ViewBuilder
    private var status: some View {
        if search.isInvalidPattern {
            Text(strings.invalidPattern)
                .foregroundStyle(Theme.down)
        } else if search.query.isEmpty {
            EmptyView()
        } else if search.matchCount == 0 {
            Text(search.runsIncrementally ? strings.noResults : strings.pressReturn)
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
            .help(strings.previous)
            .accessibilityLabel(strings.previous)

            Button {
                search.next()
            } label: {
                Image(systemName: "chevron.down").iconHitTarget(20)
            }
            .help(strings.next)
            .accessibilityLabel(strings.next)
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
                .font(.secondaryMono)
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
    var strings: SearchStrings { .localized }

    var body: some View {
        Button {
            search.toggle()
        } label: {
            Image(systemName: "magnifyingglass")
                .iconHitTarget(20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(search.isPresented ? Theme.accent : .secondary)
        .help(strings.toggle)
        .accessibilityLabel(strings.toggle)
    }
}

/// Arama çubuğunun metinleri: seçili dilde (`L10n`). Eskiden Türkçe ve
/// İngilizce iki sabit kopyaydı (API Client / Workbench).
struct SearchStrings {
    let prompt, caseSensitive, regex, close, invalidPattern, noResults, pressReturn, previous, next, toggle: String

    static var localized: SearchStrings {
        SearchStrings(
            prompt: L10n.t("search.prompt"), caseSensitive: L10n.t("search.caseSensitive"),
            regex: L10n.t("search.regex"), close: L10n.t("search.close"),
            invalidPattern: L10n.t("search.invalidPattern"), noResults: L10n.t("search.noResults"),
            pressReturn: L10n.t("search.pressReturn"), previous: L10n.t("search.previous"),
            next: L10n.t("search.next"), toggle: L10n.t("search.toggle")
        )
    }
}
