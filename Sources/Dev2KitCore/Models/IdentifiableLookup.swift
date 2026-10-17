import Foundation

public extension Collection where Element: Identifiable {
    /// Kimliği verilen ögenin konumu.
    ///
    /// `collections.firstIndex(where: { $0.id == id })` uygulama tarafında on
    /// beş yerde tekrarlanıyordu (koleksiyon, environment, TLS profili). Konum
    /// SAKLANMAZ, her erişimde kimlikten yeniden bulunur: dizi sürüklenince ya
    /// da silinince eski konum yanlış ögeye yazar.
    func firstIndex(id: Element.ID) -> Index? {
        firstIndex { $0.id == id }
    }
}
