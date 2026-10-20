import AppKit
import SwiftUI
import Dev2KitCore

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
    /// Tablo ızgarası (başlık/parametre tablosu): ayırıcı rengi, hafif.
    static let tableLine = Color(nsColor: .separatorColor)
    /// Light/dark moda göre otomatik değişen renk.
    ///
    /// Saydamlık BURADA veriliyor, dışarıda `withAlphaComponent` ile değil:
    /// dinamik renkte o çağrı rengi çözüp sabitliyor ve mod değişince yanlış
    /// tonda kalıyor.
    private static func dynamicColor(light: String, dark: String, alpha: CGFloat = 1) -> NSColor {
        dynamicColor(light: light, lightAlpha: alpha, dark: dark, darkAlpha: alpha)
    }

    /// Saydamlığı moda göre farklı olan renk (ör. koyuda yarı saydam lila
    /// kenarlık, açıkta dolu lila).
    private static func dynamicColor(light: String, lightAlpha: CGFloat, dark: String, darkAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light).withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        }
    }

    // MARK: Sözdizimi renkleri
    /// JSON key / markup tag: gf-purple; koyu zeminde sönük kaldığı için dark'ta gf-lilac-300.
    static let syntaxKey = dynamicColor(light: "#5d3ebc", dark: "#aa9cd5")
    /// String: gf-up (yeşil). Sayılar: gf-yellow; beyaz zeminde okunmadığı
    /// için light'ta gf-yellow-600. (2026-10-18'e kadar tersiydi; kullanıcı
    /// kararıyla yer değiştirdi — JSON araçlarındaki yaygın alışkanlık.)
    static let syntaxString = dynamicColor(light: "#008c29", dark: "#00a832")
    static let syntaxNumber = dynamicColor(light: "#e3bd49", dark: "#ffd300")
    /// Keyword / true-false-null: gf-down.
    static let syntaxKeyword = dynamicColor(light: "#e23737", dark: "#e23737")
    /// Attribute adları: gf-purple-700; dark'ta gf-lilac-200.
    static let syntaxAttribute = dynamicColor(light: "#4a309c", dark: "#e6e1f5")
    /// Yorumlar: gf-ink-400.
    static let syntaxComment = dynamicColor(light: "#959595", dark: "#959595")
    /// Varsayılan metin: gf-ink / gf-dark-text.
    static let editorText = dynamicColor(light: "#0e0e0e", dark: "#f3f0fe")
    /// Editör zemini: gf-bg-soft / input'larla aynı orta gri. Koyu modda
    /// editör de bir yazı alanı; kullanıcı isteğiyle (2026-10-20) mor
    /// gf-dark-bg-2 (#130d2e) yerine `inputBackground`'un grisi.
    static let editorBackgroundNS = dynamicColor(light: "#fafafa", dark: "#2a2a2e")

    // MARK: Arama vurgusu
    /// Bulunan tüm eşleşmeler. Saydam mor ton: altındaki sözdizimi rengi
    /// okunur kalsın, vurgu yalnızca "burada bir eşleşme var" desin.
    static let searchMatch = dynamicColor(light: "#5d3ebc", dark: "#aa9cd5", alpha: 0.28)
    /// Üzerinde durulan eşleşme. Dolu sarı: diğerlerinden bir bakışta ayrılsın.
    static let searchCurrentMatch = dynamicColor(light: "#e3bd49", dark: "#ffd300")
    /// Dolu sarının üstündeki yazı. Sözdizimi rengi (ör. sarı string) sarı
    /// zeminde kaybolduğu için yalnızca bu eşleşmede metin rengi sabitlenir.
    static let searchCurrentMatchText = NSColor(hex: "#0e0e0e")

    // MARK: SwiftUI renkleri
    static let accent = Color(nsColor: dynamicColor(light: "#5d3ebc", dark: "#aa9cd5"))
    static let up = Color(nsColor: NSColor(hex: "#008c29"))
    static let down = Color(nsColor: NSColor(hex: "#e23737"))
    static let warning = Color(nsColor: dynamicColor(light: "#e3bd49", dark: "#ffd300"))
    static let purple = Color(nsColor: dynamicColor(light: "#5d3ebc", dark: "#aa9cd5"))
    static let muted = Color(nsColor: dynamicColor(light: "#606a7c", dark: "#aa9cd5"))
    static let editorBackground = Color(nsColor: editorBackgroundNS)
    /// Yalnızca HTTP metodu renkleri (Postman dağılımı, 2026-10-19): paletin
    /// karşılamadığı mavi (PUT) ve pembe (OPTIONS), paletin doygunluğunda.
    static let methodBlue = Color(nsColor: dynamicColor(light: "#2f6bd8", dark: "#7fa8f5"))
    static let methodPink = Color(nsColor: dynamicColor(light: "#c23a8c", dark: "#f07fc4"))
    /// Dolgulu birincil düğmenin zemini: iki modda da marka moru (gf-purple).
    /// Koyu moddaki lila `accent` beyaz yazıyla okunmuyordu (~2,3:1).
    static let primaryFill = Color(nsColor: NSColor(hex: "#5d3ebc"))
    /// Alandaki `{{değişken}}`: tanımlıysa mor, tanımsızsa `down`.
    static let variable = purple

    // MARK: Input alanları
    //
    // Kullanıcı seçimi (2026-10-20): tüm yazı alanları aynı zemin, kenarlık
    // ve odak renklerini kullanır. Açık mod lila zemin (gf-lilac-50); koyu
    // mod nötr "orta gri" (editör zemini de aynı gri): mor yalnızca odakta
    // kalsın. Koyu griler palette yok (paletin koyu tonları mor), türetildi.
    // Uygulayan: `InputChrome`.

    /// Zemin: gf-lilac-50 / orta gri.
    static let inputBackground = Color(nsColor: dynamicColor(light: "#f9f7ff", dark: "#2a2a2e"))
    /// Kenarlık: gf-lilac-200 / gri.
    static let inputBorder = Color(nsColor: dynamicColor(light: "#e6e1f5", dark: "#3f3f45"))
    /// Üzerine gelince kenarlık: gf-lilac-300 / açık gri.
    static let inputBorderHover = Color(nsColor: dynamicColor(light: "#aa9cd5", dark: "#5a5a62"))
    /// Odak kenarlığı: gf-purple / gf-lilac-300 (accent ile aynı).
    static let inputFocus = accent
    /// Odak kenarlığının dışındaki yumuşak halka.
    static let inputFocusRing = Color(nsColor: dynamicColor(light: "#5d3ebc", lightAlpha: 0.18, dark: "#aa9cd5", darkAlpha: 0.25))
    /// Kapalı alan zemini: gf-bg-soft / koyu gri.
    static let inputDisabledBackground = Color(nsColor: dynamicColor(light: "#fafafa", dark: "#222225"))
    /// Kapalı alan kenarlığı: gf-line / koyu gri.
    static let inputDisabledBorder = Color(nsColor: dynamicColor(light: "#e8e8e8", dark: "#303035"))
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
    /// HTTP metodunun rengi; kenar çubuğu, sekmeler ve metot seçici aynı
    /// rengi kullanır. Dağılım Postman'daki gibi (kullanıcı isteği,
    /// 2026-10-19), tonlar bizim paletten.
    static func color(for method: HTTPMethod) -> Color {
        switch method {
        case .get, .head: return up
        case .post: return warning
        case .put: return methodBlue
        case .patch: return purple
        case .delete: return down
        case .options: return methodPink
        }
    }
}

/// Yazı ölçeği (docs/TASARIM.md §3).
///
/// macOS'un `.caption`/`.caption2`'si 10 pt; Retina olmayan ekranlarda (ör.
/// 2560×1440 ölçeklemesiz, ~109 ppi) ikincil metinler okunmuyordu. İkincil
/// metin 11 pt'ye çıktı (Apple'ın ikincil metin önerisi), en küçükler
/// (rozet, sayaç, satır numarası) 10 pt'de kaldı. Doğrudan `.caption`
/// kullanılmaz; ölçek tek yerden değişsin diye bunlar kullanılır.
extension Font {
    /// İpucu, bilgi satırı, bölme başlığı, durum satırı.
    static let secondaryText = Font.system(size: 11)
    /// Rozet, sayaç, çok küçük etiket.
    static let tinyText = Font.system(size: 10)
    /// İkincil makine metni: URL parçası, yol, değişken adı.
    static let secondaryMono = Font.system(size: 11, design: .monospaced)
    static let tinyMono = Font.system(size: 10, design: .monospaced)
}

/// Sekme görünümü (API Client ve Workbench ortak): üst köşeleri yuvarlak
/// sekme, seçilide editör zemini ve üstte vurgu çizgisi (şeklin içinde).
/// Kullanıcı isteği (2026-10-19): köşeli sekmeler sert görünüyordu.
struct TabChrome: ViewModifier {
    let isSelected: Bool
    let hovering: Bool
    static let radius: CGFloat = 8
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: Self.radius, topTrailingRadius: Self.radius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            // Görünüm (stil değil) arka planı güvenli alana taşmaz: seçili
            // sekme pencerenin tepesine kadar uzanmasın.
            .background {
                shape.fill(isSelected ? Theme.editorBackground : (hovering ? Color.primary.opacity(0.06) : .clear))
            }
            .overlay(alignment: .top) {
                if isSelected { Rectangle().fill(Theme.accent).frame(height: 2) }
            }
            .clipShape(shape)
            .contentShape(shape)
            .padding(.top, 4)
    }
}

/// Birincil eylem ("Gönder"): `Theme.primaryFill` dolgu, beyaz yazı. Sistemin
/// vurgulu düğmesi pencere etkin değilken griye dönüyor; birincil eylem
/// her durumda belli olsun (API Client yeni düzen, 2026-10-20).
struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            // Yükseklik vermeyen yerlerde (sonuç penceresi, şeritler) ince
            // bir şerit gibi kalmasın; "Gönder" kendi yüksekliğini veriyor.
            .frame(minHeight: 22)
            .background(Theme.primaryFill.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.18)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Kenar çubuğu sütununun zemini: sistemin kenar çubuğu malzemesi (buzlu,
/// pencerenin arkasını gösterir). Listenin `.sidebar` stili yalnızca listenin
/// arkasını boyuyor; altındaki Token Factory ve alt çubuk da aynı camda
/// olsun diye bütün sütuna verilir (API Client yeni düzen, 2026-10-20).
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
