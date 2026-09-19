import AppKit
import SwiftUI
import SecoraCore

/// Kullanıcının entegre sistemindeki marka (gf-*) paleti.
/// Ham değerler:
///   gf-purple #5d3ebc · gf-purple-700 #4a309c · gf-purple-900 #251a49 · gf-purple-ink #1a1340
///   gf-yellow #ffd300 · gf-yellow-600 #e3bd49
///   gf-bg #ffffff · gf-bg-soft #fafafa · gf-lilac-50 #f9f7ff · gf-lilac #f3f0fe
///   gf-lilac-200 #e6e1f5 · gf-lilac-300 #aa9cd5
///   gf-ink #0e0e0e · gf-ink-700 #3e3e3e · gf-ink-500 #606a7c · gf-ink-400 #959595
///   gf-line #e8e8e8 · gf-up #008c29 · gf-down #e23737 · gf-card-purple #2f205d
///   gf-dark-bg #1c1340 · gf-dark-bg-2 #130d2e · gf-dark-surface #2a1f55
///   gf-dark-text #f3f0fe · gf-dark-muted #aa9cd5
enum Theme {
    /// Light/dark moda göre otomatik değişen renk.
    private static func dynamicColor(light: String, dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    // MARK: Sözdizimi renkleri
    /// JSON key / markup tag: gf-purple; koyu zeminde sönük kaldığı için dark'ta gf-lilac-300.
    static let syntaxKey = dynamicColor(light: "#5d3ebc", dark: "#aa9cd5")
    /// String: gf-yellow; beyaz zeminde okunmadığı için light'ta gf-yellow-600.
    static let syntaxString = dynamicColor(light: "#e3bd49", dark: "#ffd300")
    /// Sayılar: gf-up.
    static let syntaxNumber = dynamicColor(light: "#008c29", dark: "#00a832")
    /// Keyword / true-false-null: gf-down.
    static let syntaxKeyword = dynamicColor(light: "#e23737", dark: "#e23737")
    /// Attribute adları: gf-purple-700; dark'ta gf-lilac-200.
    static let syntaxAttribute = dynamicColor(light: "#4a309c", dark: "#e6e1f5")
    /// Yorumlar: gf-ink-400.
    static let syntaxComment = dynamicColor(light: "#959595", dark: "#959595")
    /// Varsayılan metin: gf-ink / gf-dark-text.
    static let editorText = dynamicColor(light: "#0e0e0e", dark: "#f3f0fe")
    /// Editör zemini: gf-bg-soft / gf-dark-bg-2.
    static let editorBackgroundNS = dynamicColor(light: "#fafafa", dark: "#130d2e")

    // MARK: SwiftUI renkleri
    static let accent = Color(nsColor: dynamicColor(light: "#5d3ebc", dark: "#aa9cd5"))
    static let up = Color(nsColor: NSColor(hex: "#008c29"))
    static let down = Color(nsColor: NSColor(hex: "#e23737"))
    static let warning = Color(nsColor: dynamicColor(light: "#e3bd49", dark: "#ffd300"))
    static let purple = Color(nsColor: dynamicColor(light: "#5d3ebc", dark: "#aa9cd5"))
    static let muted = Color(nsColor: dynamicColor(light: "#606a7c", dark: "#aa9cd5"))
    static let editorBackground = Color(nsColor: editorBackgroundNS)
}

private extension NSColor {
    /// "#rrggbb" biçimindeki hex değerinden sRGB renk üretir.
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Theme {
    /// HTTP metodunun rengi; kenar çubuğu ve sekmeler aynı rengi kullanır.
    static func color(for method: HTTPMethod) -> Color {
        switch method {
        case .get: return up
        case .post: return warning
        case .put, .patch: return purple
        case .delete: return down
        case .head, .options: return muted
        }
    }
}
