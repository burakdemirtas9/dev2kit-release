import Foundation

/// İstek düzenleyicinin sekmeleri.
///
/// Neden view'da değil burada: ⌘1…⌘4 menü komutları `RequestDetailView`'ın
/// yerel `@State`'ine erişemez. Yan fayda: istekler arasında geçiş yapınca
/// açık sekme korunur.
enum EditorTab: String, CaseIterable, Identifiable {
    case headers = "Headers"
    case body = "Body"
    case auth = "Auth"
    case params = "Query"
    /// Yalnızca Token Factory isteklerinde: yanıttaki alan ve değişken.
    case token = "Token"

    var id: String { rawValue }

    /// İstekte gösterilecek sekmeler.
    static func available(isTokenFactory: Bool) -> [EditorTab] {
        isTokenFactory ? allCases : allCases.filter { $0 != .token }
    }
}
