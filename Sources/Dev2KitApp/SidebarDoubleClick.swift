import AppKit
import SwiftUI

/// "Çift tıkla → sekmeyi kalıcı yap" davranışı, satırın hit-test'ine dokunmadan.
///
/// Neden AppKit: bu gesture satır içeriğine `TapGesture(count: 2)` olarak
/// bağlıyken macOS 26'da satırdaki TEK tıklamayı yutuyordu. Ölçüldü (satır 19):
/// AppKit satır çerçevesi y 651–675, SwiftUI'nin çizdiği içerik y 655–671;
/// içeriğin üstüne yapılan tıklamalar (655, 660, 664, 670) hiçbir seçim
/// yapmadı, yalnızca içeriğin dışındaki 672 seçti. Kullanıcı bunu "tıklamak
/// için imleci yazının altına getirmem gerekiyor" olarak yaşıyordu.
///
/// Çözüm: satır içeriğinde gesture YOK. Çift tıklama uygulamanın kendi olay
/// akışından yakalanıyor (local monitor — sistem izni gerektirmez, yalnızca
/// bu uygulamanın olaylarını görür). Hit-test'e hiç karışmadığı için satırın
/// her yeri tıklanabilir kalır.
@MainActor
enum SidebarDoubleClick {
    private static var monitor: Any?
    private static var lastDown: (time: TimeInterval, point: CGPoint)?

    /// `pin`: o an seçili isteği kalıcı sekme yapar.
    static func install(pin: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            if isDoubleClick(event), isInsideSidebarList(event) {
                MainActor.assumeIsolated { pin() }
            }
            return event
        }
    }

    /// Normalde `clickCount` yeterli. Yedek ölçüm, olayı üreten kaynak tıklama
    /// sayısını taşımadığında devreye girer (sentetik/uzaktan olaylar, bazı
    /// giriş aygıtları); eşik kullanıcının sistem ayarından alınır.
    private static func isDoubleClick(_ event: NSEvent) -> Bool {
        defer { lastDown = (event.timestamp, event.locationInWindow) }
        if event.clickCount >= 2 { return true }
        guard let last = lastDown,
              event.timestamp - last.time <= NSEvent.doubleClickInterval else { return false }
        let point = event.locationInWindow
        return abs(point.x - last.point.x) < 6 && abs(point.y - last.point.y) < 6
    }

    /// Yalnızca ana penceredeki liste; sheet'lerdeki listeler (geçmiş, TLS)
    /// ayrı pencere olduğu için buraya düşmez.
    private static func isInsideSidebarList(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === NSApp.mainWindow,
              let root = window.contentView,
              let hit = root.hitTest(event.locationInWindow) else { return false }
        var view: NSView? = hit
        while let candidate = view {
            if candidate is NSTableView { return true }
            view = candidate.superview
        }
        return false
    }
}
