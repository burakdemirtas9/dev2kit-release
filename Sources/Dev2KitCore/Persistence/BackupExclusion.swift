import Foundation

/// Hassas dosyaları Time Machine yedeğinden hariç tutar.
///
/// Neden: anahtar dosyadayken şifreli veriyle aynı yedeğe gidiyordu; yedeği
/// ele geçiren ikisini birlikte alıp çözebiliyordu. Veri ve anahtar BİRLİKTE
/// hariç tutulur: yalnızca anahtar hariç tutulsaydı geri yüklemede açılamayan
/// şifreli veri ve "anahtarı geri koy" hatası kalırdı. Bedeli: yedekten
/// kurulan Mac'te vault ve geçmiş boş gelir (Keychain'deki "yalnızca bu
/// cihaz" kaydıyla aynı niyet).
///
/// İşaret dosyanın kendisine yazılır; yönetici ya da onay gerekmez. Dosya
/// yenisiyle değişince kaybolur, bu yüzden her yazımda yeniden konur.
/// En iyi çaba: işareti desteklemeyen dosya sisteminde kayıt yine yapılır.
/// Time Machine dışındaki yedek araçları işareti dikkate almayabilir.
enum BackupExclusion {
    static func exclude(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Yalnızca var olanları işaretler (önceki sürümün yazdığı dosyalar).
    static func excludeExisting(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            exclude(url)
        }
    }
}
