import SwiftUI
import Dev2KitCore

/// Araç çubuğundaki Ayarlar düğmesi ve dairesel menüsü.
///
/// Kapalıyken: tek cam daire + çevresinde seyrek hare. Tıklanınca hare
/// söner, menü çocuk pencerede açılır; menünün tetikleyicisi bu düğmenin tam
/// üstüne oturur ve kapatma düğmesine dönüşür. Tamamen kapanınca pencere
/// gizlenir, düğme ve hare geri gelir.
struct SettingsMenuButton: View {
    /// Çizim sırasında okunur: görünüm/dil değişince açık menünün simgeleri
    /// de güncellenir (gözlemlenen durumu okuyan bir kapanış).
    let items: () -> [RadialMenuItem]
    var style = RadialMenuStyle()
    var haloStyle = SettingsHaloStyle()

    @State private var model = RadialMenuModel()
    @State private var panel = RadialMenuPanel()
    @State private var anchor = ScreenAnchorReader()
    /// Menü penceresi görünürken araç çubuğundaki daire gizlenir (iki cam
    /// üst üste binmesin); hare yalnızca menü tamamen kapalıyken.
    @State private var isPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SettingsHalo(isVisible: model.phase == .closed && !isPresented, buttonDiameter: style.itemDiameter, style: haloStyle)
            Button(action: present) {
                Image(systemName: "gearshape")
                    .font(.system(size: style.iconSize, weight: .semibold))
                    .frame(width: style.itemDiameter, height: style.itemDiameter)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(ToolbarGlassCircle())
            .opacity(isPresented ? 0 : 1)
            .background(ScreenAnchor(reader: anchor))
            .help(L10n.t("settings.title"))
            .accessibilityLabel(L10n.t("settings.title"))
        }
        .frame(width: style.itemDiameter + 2 * haloStyle.extent, height: style.itemDiameter + 2 * haloStyle.extent)
        .onChange(of: items().map(\.id)) {
            // Öğeler değişti (mod geçişi): açık menü eski listeyle kalmasın.
            dismissImmediately()
        }
        .onDisappear { dismissImmediately() }
    }

    private func present() {
        guard !isPresented, let window = anchor.window, let center = anchor.centerInScreen else { return }
        let count = items().count + 1
        model.prepare(count: count)
        model.onFullyClosed = {
            panel.hide()
            isPresented = false
        }
        panel.onDismissRequest = { model.close(RadialMenuTiming(style: style, reduceMotion: reduceMotion)) }
        panel.onForceClose = { dismissImmediately() }
        panel.onKey = { handleKey($0) }
        panel.isBlocking = { model.isExpanded }

        let canvas = RadialMenuView.canvas(count: count, style: style)
        let menu = SettingsMenuContent(model: model, items: items, style: style)
        panel.show(menu, size: canvas.size, anchor: canvas.anchor, anchorInScreen: center, parent: window)
        isPresented = true
        // Pencere bir sonraki karede çizilsin, sonra açılış başlasın.
        DispatchQueue.main.async {
            model.open(RadialMenuTiming(style: style, reduceMotion: reduceMotion))
        }
    }

    /// Klavyeyle gezinme: Tab / → / ↓ saat yönünde, ⇧Tab / ← / ↑ tersine;
    /// Return / Boşluk odaktaki öğeyi çalıştırır. Diğer tuşlar geçer.
    private func handleKey(_ event: NSEvent) -> Bool {
        let timing = RadialMenuTiming(style: style, reduceMotion: reduceMotion)
        switch event.keyCode {
        case 48: // Tab
            model.moveFocus(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        case 124, 125: // → ↓
            model.moveFocus(by: 1)
        case 123, 126: // ← ↑
            model.moveFocus(by: -1)
        case 36, 76, 49: // Return, Enter, Boşluk
            guard let index = model.focusedIndex else { return false }
            if index == 0 {
                model.close(timing)
            } else {
                let items = items()
                guard items.indices.contains(index - 1) else { return false }
                let item = items[index - 1]
                if item.closesMenu { model.reset() }
                item.action()
            }
        default:
            return false
        }
        return true
    }

    private func dismissImmediately() {
        guard isPresented || model.phase != .closed else { return }
        model.reset()
        panel.hide()
        isPresented = false
    }
}

/// Araç çubuğundaki kapalı düğmenin camı (menüdeki tetikleyiciyle aynı görünüm).
/// Geçmiş düğmesi de aynısını kullanır.
struct ToolbarGlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

/// Paneldeki içerik: öğeler her çizimde yeniden okunur.
private struct SettingsMenuContent: View {
    let model: RadialMenuModel
    let items: () -> [RadialMenuItem]
    let style: RadialMenuStyle

    var body: some View {
        RadialMenuView(
            model: model,
            items: items(),
            style: style,
            triggerTitle: L10n.t("settings.title"),
            closeTitle: L10n.t("settings.close"),
            triggerIcon: "gearshape",
            closeIcon: "xmark"
        )
        .environment(\.locale, L10n.language.locale)
    }
}
