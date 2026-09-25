import Foundation

/// Dar alanlarda (toolbar seçicisi gibi) gösterilecek adların kısaltılması.
///
/// Kısaltma yalnızca *gösterim* içindir: kayıtlı ad hiçbir zaman değişmez ve
/// açılır listede, düzenleme ekranında tam haliyle görünür. Amaç tek bir uzun
/// adın arayüzdeki bir bölümü sınırsız genişletmesini engellemek.
public enum DisplayName {
    /// Toolbar'daki environment seçicisinin üst sınırı. Yaygın adlar
    /// ("test", "preprod-gateway") sığacak kadar geniş, toolbar'ı itmeyecek
    /// kadar dar olacak şekilde seçildi.
    public static let environmentPickerLimit = 24

    /// `limit` karakteri aşan adı sonundan kırpar ve "…" ekler.
    ///
    /// Sayım grapheme cluster üzerinden yapılır; "ğ" gibi Türkçe harfler ve
    /// emoji tek karakter sayılır. Kırpma noktasında kalan boşluk temizlenir
    /// ki sonuç "Uzun ad …" gibi görünmesin. Baştaki/sondaki boşluklar her
    /// durumda atılır; yalnızca boşluktan oluşan ad boş string döner (çağıran
    /// taraf kendi yer tutucusunu koyar, böylece Core'da arayüz metni olmaz).
    public static func truncated(_ name: String, limit: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return "" }
        guard trimmed.count > limit else { return trimmed }
        // "…" de bir karakter yer kapladığı için bütçeden düşülür; sonuç
        // hiçbir zaman limit'ten uzun olmaz.
        let head = String(trimmed.prefix(limit - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head + "…"
    }
}
