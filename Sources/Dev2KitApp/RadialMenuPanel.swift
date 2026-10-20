import AppKit
import SwiftUI

/// Açık dairesel menünün penceresi: saydam, kenarsız, ana pencerenin çocuğu.
///
/// Neden ayrı pencere: menü araç çubuğundaki düğmenin ALTINA, içeriğin ve
/// araç çubuğunun üstüne taşar. Araç çubuğu öğesi kendi yüksekliğinin
/// dışına çizemez; içerik katmanı da araç çubuğunun altında kalır. Çocuk
/// pencere ana pencereyle birlikte taşınır.
///
/// Anahtar pencere olmaz (ana pencerenin başlığı sönmesin); Esc ve dışarı
/// tıklama uygulama içi olay izleyicisiyle yakalanır.
@MainActor
final class RadialMenuPanel {
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// Esc, dışarı tıklama: animasyonlu kapat.
    var onDismissRequest: (() -> Void)?
    /// Menü açık mı (açılıyor ya da açık). Kapanırken dışarı tıklama
    /// engellenmez: menü zaten gidiyor, tıklama hedefine ulaşsın.
    var isBlocking: (() -> Bool)?
    /// Menü açıkken klavye (Tab, oklar, Return, Boşluk). `true`: tuş
    /// menüde kullanıldı, arkadaki pencereye gitmez.
    var onKey: ((NSEvent) -> Bool)?
    /// Pencere yeniden boyutlandı/kapandı, uygulama arka plana geçti:
    /// düğmenin yeri belirsiz, hemen kapat.
    var onForceClose: (() -> Void)?

    var isShown: Bool { panel?.isVisible == true }

    /// Menüyü, tetikleyicinin merkezi `anchorInScreen` noktasına gelecek
    /// şekilde gösterir. `anchor`: tetikleyicinin içerikteki yeri (sol üstten).
    func show<Content: View>(_ content: Content, size: CGSize, anchor: CGPoint, anchorInScreen: CGPoint, parent: NSWindow) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: content)

        // Ekran koordinatı y yukarı; içerik y aşağı.
        var frame = NSRect(
            x: anchorInScreen.x - anchor.x,
            y: anchorInScreen.y + anchor.y - size.height,
            width: size.width,
            height: size.height
        )
        frame = Self.clamped(frame, inside: parent.frame, screen: (parent.screen ?? NSScreen.main)?.visibleFrame)
        panel.setFrame(frame, display: false)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        install(parent: parent)
    }

    /// Menü pencerenin ve ekranın dışına taşmasın: gerekirse içeri kaydırılır.
    /// Çark sol üstte, pencere düğmelerinden sonra durduğu için normalde
    /// kaydırma gerekmez; kaydırılırsa kapatma düğmesi çarkla hizasını
    /// kaybeder (bu yüzden çarkın yeri menüye yer bırakacak şekilde seçildi).
    static func clamped(_ frame: NSRect, inside window: NSRect, screen: NSRect?) -> NSRect {
        var bounds = window
        if let screen { bounds = bounds.intersection(screen) }
        guard !bounds.isNull, bounds.width >= frame.width, bounds.height >= frame.height else { return frame }
        var result = frame
        result.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        result.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        return result
    }

    func hide() {
        removeMonitors()
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Görünüm ağacı bırakılır: kapalıyken animasyon/gözlem çalışmasın.
        panel.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = KeylessPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        return panel
    }

    private func install(parent: NSWindow) {
        removeMonitors()
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShown else { return event }
            if event.keyCode == 53 { // Esc
                self.onDismissRequest?()
                return nil
            }
            return self.onKey?(event) == true ? nil : event
        } as Any)
        // Menü açıkken arkadaki hiçbir şey tıklanmaz: dışarı tıklama yalnızca
        // menüyü kapatır, olay yutulur (kullanıcı isteği, 2026-10-20: menü
        // açıkken Geçmiş'e tıklayınca geçmiş de açılıyordu).
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, self.isShown, event.window !== panel,
                  self.isBlocking?() ?? true else { return event }
            self.onDismissRequest?()
            return nil
        } as Any)
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onForceClose?() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onForceClose?() }
        })
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

/// Tıklanınca anahtar olmayan panel: ana pencere etkin kalır.
private final class KeylessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Bir görünümün ekrandaki yerini okumak için AppKit görünümü.
struct ScreenAnchor: NSViewRepresentable {
    let reader: ScreenAnchorReader

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        reader.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        reader.view = nsView
    }
}

@MainActor
final class ScreenAnchorReader {
    weak var view: NSView?

    /// Görünümün merkezi, ekran koordinatında (y yukarı).
    var centerInScreen: CGPoint? {
        guard let view, let window = view.window else { return nil }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    var window: NSWindow? { view?.window }
}
