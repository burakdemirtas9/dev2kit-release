import SwiftUI

/// İstek düzenleyicinin sekme seçicisi (Headers / Body / Auth / Query / Token).
///
/// Neden sistemin segmentli kontrolü değil (docs/TASARIM.md §1 istisnası):
/// içeriği olan sekmenin yanında sarı nokta isteniyor; segmentli kontrol
/// renkli resmi hiç çizmiyor, metin olarak `•` ise yazı renginde kalıyor
/// (2026-10-18, ekran dışında çizilip denendi). Görünüm segmentli kontrole
/// benzetildi; ⌘1…⌘5 menüden geldiği için aynen çalışır.
struct EditorTabPicker: View {
    @Binding var selection: EditorTab
    let tabs: [EditorTab]
    /// İçeriği olan sekmeler: yanında sarı nokta.
    let marked: Set<EditorTab>

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection
                let isMarked = marked.contains(tab)
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 5) {
                        Text(tab.rawValue)
                        if isMarked {
                            Circle()
                                .fill(Theme.warning)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 22)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .background(isSelected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(isMarked ? "\(tab.rawValue) — has content" : tab.rawValue)
                .accessibilityLabel(tab.rawValue)
                .accessibilityValue(isMarked ? "içerik var" : "")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
