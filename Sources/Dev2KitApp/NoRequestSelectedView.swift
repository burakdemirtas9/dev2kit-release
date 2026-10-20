import AppKit
import SwiftUI
import Dev2KitCore

/// İstek seçili değilken sağ panel: yalnızca "yeni bir istek oluştur"
/// yazısı tıklanabilir (marka moru). Tek tıkla varsayılan istek
/// Koleksiyonsuz'a eklenir ve adres alanı odakta açılır; ara pencere yok
/// (kullanıcı isteği, 2026-10-20).
struct NoRequestSelectedView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ContentUnavailableView {
            Label(L10n.t("empty.noRequest.title"), systemImage: "paperplane")
        } description: {
            HStack(spacing: 0) {
                Text(L10n.t("empty.noRequest.prefix"))
                InlineActionLink(L10n.t("empty.noRequest.create")) { appState.createUngroupedRequest() }
                Text(L10n.t("empty.noRequest.suffix"))
            }
        }
    }
}

/// Metin içindeki eylem bağlantısı: gf-purple, üzerine gelince altı çizili
/// ve el imleci, klavye odağında çerçeve; ⏎ ve boşluk tuşuyla çalışır.
struct InlineActionLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(Theme.purple)
                .underline(hovering || focused)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.purple.opacity(hovering ? 0.10 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.purple.opacity(focused ? 0.8 : 0), lineWidth: 1.5)
                        .padding(-2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return) { action(); return .handled }
        .onKeyPress(.space) { action(); return .handled }
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // İmleç üstündeyken görünüm kalkarsa el imleci takılı kalmasın.
        .onDisappear {
            if hovering { NSCursor.pop() }
            hovering = false
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}
