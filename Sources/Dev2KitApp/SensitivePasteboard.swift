import AppKit

/// Secret/token taşıyabilen metnin panoya kopyalanması.
///
/// Neden ayrı (güvenlik incelemesi, 2026-10-21): genel pano Evrensel Pano
/// (Handoff) ile aynı Apple hesabındaki diğer cihazlara gidiyor ve pano
/// yöneticileri geçmişte saklıyor. Token Factory token'ları bilerek yalnızca
/// bellekte tutuluyor; "kopyala" onları sessizce başka cihaza/geçmişe
/// taşımasın.
/// - `.currentHostOnly`: yalnızca bu Mac'te (Evrensel Pano'ya gitmez).
/// - `org.nspasteboard.ConcealedType`: pano yöneticilerine "geçmişte tutma"
///   işareti (nspasteboard.org kuralı; uyan uygulamalar saklamaz).
/// Bu Mac'te yapıştırma eskisi gibi çalışır.
enum SensitivePasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
    }
}
