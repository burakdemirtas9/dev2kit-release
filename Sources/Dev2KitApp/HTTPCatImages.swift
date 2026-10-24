import AppKit
import Dev2KitCore

/// Status alanındaki kedi görsellerini ihtiyaç oldukça yükler ve tutar.
///
/// Bir kod ilk istendiğinde diskten (paket içinden) bir kez okunur; sonraki
/// çift tıklamalar bellekteki görseli kullanır. Hiç istenmeyen kod yüklenmez.
/// Görsel küçük (128 px, ~20 KB), 15 adet; önbelleğin sınırı gerekmiyor.
@MainActor
enum HTTPCatImages {
    private static var cache: [Int: NSImage] = [:]
    /// Okunamayan kod bir daha denenmez (her tıklamada disk yok).
    private static var unavailable: Set<Int> = []

    /// Kodun görseli; eşleşme ya da dosya yoksa `nil` (gösterim değişmez).
    static func image(for statusCode: Int) -> NSImage? {
        if let cached = cache[statusCode] { return cached }
        guard !unavailable.contains(statusCode),
              let name = HTTPCats.resourceName(for: statusCode),
              let url = resourceURL(name),
              let image = NSImage(contentsOf: url) else {
            unavailable.insert(statusCode)
            return nil
        }
        cache[statusCode] = image
        return image
    }

    /// `.app` içinde `Bundle.main` (make-app.sh kopyalar). `Bundle.module`
    /// yalnızca bundle'sız çalışmada (`swift run`, testler): `.app`'te
    /// çağrılırsa SPM kaynak paketini derleme dizininde arar, başka Mac'te
    /// uygulamayı çökertir (bkz. Dev2KitApp ikon yüklemesi).
    private static func resourceURL(_ name: String) -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.url(forResource: name, withExtension: "png", subdirectory: HTTPCats.directory)
        }
        return Bundle.module.url(forResource: name, withExtension: "png", subdirectory: HTTPCats.directory)
    }
}
