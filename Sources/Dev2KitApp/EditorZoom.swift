import AppKit

/// Kod editörlerinin yazı boyutu (⌘+ / ⌘− / ⌘0). Tüm editörler (gövde,
/// yanıt, Workbench girdi/çıktı, Diff Checker) aynı boyutu kullanır;
/// seçim UserDefaults'ta, bir sonraki açılışta hatırlanır.
enum EditorZoom {
    static let key = "editorFontSize"
    /// macOS'un varsayılan metin boyutu.
    static let standard: Double = NSFont.systemFontSize
    static let range: ClosedRange<Double> = 9...28

    static func zoomed(_ size: Double, by step: Double) -> Double {
        min(max(size + step, range.lowerBound), range.upperBound)
    }

    static func font(_ size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Satır numarası boyutu editörle orantılı (varsayılanda 10 pt).
    static func gutterSize(_ size: Double) -> Double {
        (size * 10 / standard).rounded()
    }
}
