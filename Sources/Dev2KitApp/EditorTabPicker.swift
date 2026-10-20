import SwiftUI
import Dev2KitCore

/// İstek düzenleyicinin sekme seçicisi (Headers / Body / Auth / Query / Token).
///
/// Neden sistemin segmentli kontrolü değil (docs/TASARIM.md §1 istisnası):
/// içeriği olan sekmenin yanında sarı nokta isteniyor; segmentli kontrol
/// renkli resmi hiç çizmiyor, metin olarak `•` ise yazı renginde kalıyor
/// (2026-10-18, ekran dışında çizilip denendi). 2026-10-20'den beri sola
/// yaslı düz sekmeler, seçili olan camlı zeminde (API Client yeni düzen);
/// ⌘1…⌘5 menüden geldiği için aynen çalışır.
struct EditorTabPicker: View {
    @Binding var selection: EditorTab
    let tabs: [EditorTab]
    /// İçeriği olan sekmeler: yanında sarı nokta.
    let marked: Set<EditorTab>
    /// Sekmenin yanındaki sayı (ör. Headers'ta açık başlık sayısı); 0 gösterilmez.
    var counts: [EditorTab: Int] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection
                let isMarked = marked.contains(tab)
                let count = counts[tab] ?? 0
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 5) {
                        Text(tab.rawValue)
                            .fontWeight(isSelected ? .medium : .regular)
                        if count > 0 {
                            Text("\(count)")
                                .font(.tinyText.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                                .background(isSelected ? Theme.accent.opacity(0.22) : Color.primary.opacity(0.10), in: Capsule())
                        }
                        if isMarked {
                            Circle()
                                .fill(Theme.warning)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 24)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .background { if isSelected { SelectedChip() } }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(count > 0 ? L10n.plural("tabs.activeCount", count: count, tab.rawValue) : isMarked ? L10n.t("tabs.hasContent", tab.rawValue) : tab.rawValue)
                .accessibilityLabel(tab.rawValue)
                .accessibilityValue(count > 0 ? L10n.plural("tabs.activeCount.short", count: count) : isMarked ? L10n.t("tabs.hasContent.short") : "")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// Seçili sekmenin/seçeneğin zemini: macOS 26'da cam, öncesinde hafif dolgu
/// (API Client yeni düzen, 2026-10-20). İstek sekmeleri ve tablo kipleri.
struct SelectedChip: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}
