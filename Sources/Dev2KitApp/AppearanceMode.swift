import Dev2KitCore
import AppKit

/// Görünüm tercihi: sistem, açık, koyu.
enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: return L10n.t("appearance.system")
        case .light: return L10n.t("appearance.light")
        case .dark: return L10n.t("appearance.dark")
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// Ayarlar menüsünde tıklama: yalnızca Koyu ↔ Açık (kullanıcı isteği,
    /// 2026-10-20; "Sistem" sağ tıkla seçilir). Sistemdeyken ekranda görünenin
    /// tersine geçer: tıklama her zaman görünür bir değişiklik yapsın.
    func toggled(systemIsDark: Bool) -> AppearanceMode {
        switch self {
        case .dark: return .light
        case .light: return .dark
        case .system: return systemIsDark ? .light : .dark
        }
    }

    /// Seçimi uygulamaya uygular (`nil` = sistemi izle).
    func apply() {
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
