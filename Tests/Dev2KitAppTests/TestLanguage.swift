import XCTest
@testable import Dev2KitCore

/// Metin bekleyen testler makinenin diline bağlı olmasın diye arayüz dilini
/// test süresince sabitler ve sonra eski haline döndürür. Sınıfta:
/// `override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }`
func withLanguage(_ language: AppLanguage, _ body: () -> Void) {
    let saved = Localizer.shared.language
    Localizer.shared.language = language
    defer { Localizer.shared.language = saved }
    body()
}
