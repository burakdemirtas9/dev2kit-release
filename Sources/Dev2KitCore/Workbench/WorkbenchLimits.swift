import Foundation

/// Workbench ve Diff Checker girdi/çıktı sınırları (docs/V2.md "Sınırlar").
///
/// Ölçüm (M4, release, 2026-10-18, ana thread'in en uzun donması):
/// - Çok satırlı metin editörde doğrusal: 5 MB 0,3 sn, 20 MB 1,0 sn.
/// - TEK satırlı metin (sıkıştırılmış JSON) macOS metin yerleştiricisinde
///   pahalı: 2 MB 1,05 sn, 5 MB 2,6 sn — satır baştan sona yerleşmek zorunda.
///
/// Kullanıcı kararı (2026-10-18): girdi başına 20 MB; 2 MB'tan uzun satır
/// editörde gösterilmez. İkisinde de kullanıcı açıkça bilgilendirilir.
public enum WorkbenchLimits {
    /// Bir girdinin (ve editörde gösterilen bir çıktının) üst sınırı.
    /// Ondalık: boyutlar arayüzde 1000 tabanlı gösteriliyor (`TextStats.size`,
    /// Finder gibi); 1024 tabanlı sınır mesajda "21 MB" görünüyordu.
    public static let maxInputBytes = 20_000_000
    /// Editörde gösterilebilecek en uzun satır.
    public static let maxEditorLineBytes = 2_000_000
    /// Diff satır görünümünde bir satırın gösterilen kısmı.
    public static let maxDisplayedLineCharacters = 10_000

    /// Değişiklik sonrası metnin UTF-8 boyutu.
    public static func resultingBytes(of current: NSString, replacing range: NSRange, with replacement: String) -> Int {
        (current as String).utf8.count - current.substring(with: range).utf8.count + replacement.utf8.count
    }

    /// UTF-16 uzunluğundan boyutun üst sınırı (birim başına en çok 3 bayt):
    /// kesin sayım gerekmeden "sınırın altında" denebilsin, her tuşta tüm
    /// metin sayılmasın.
    public static func mayExceed(utf16Length: Int, limit: Int) -> Bool {
        utf16Length * 3 > limit
    }

    /// `limit` bayttan uzun satır var mı; bulunca durur.
    public static func hasLine(longerThan limit: Int, in text: String) -> Bool {
        guard text.utf8.count > limit else { return false }
        var run = 0
        for byte in text.utf8 {
            if byte == 0x0A || byte == 0x0D {
                run = 0
            } else {
                run += 1
                if run > limit { return true }
            }
        }
        return false
    }

    /// Editörde gösterilemeyecek metin: sınırdan büyük ya da çok uzun satırlı.
    public static func isTooLargeForEditor(_ text: String) -> Bool {
        text.utf8.count > maxInputBytes || hasLine(longerThan: maxEditorLineBytes, in: text)
    }

    /// Diff satırında gösterilecek kısım; uzun satır kırpılır.
    public static func displayed(line: String) -> String {
        guard line.utf16.count > maxDisplayedLineCharacters else { return line }
        let prefix = String(line.prefix(maxDisplayedLineCharacters))
        return prefix + " … (\(TextStats.size(line.utf8.count)) line, truncated)"
    }

    // MARK: Mesajlar (Workbench arayüzü İngilizce)

    public static func tooLargeMessage(bytes: Int) -> String {
        "Not added: the result would be \(TextStats.size(bytes)). The limit is \(TextStats.size(maxInputBytes)) per input."
    }

    public static let longLineEditMessage =
        "Not added: lines longer than \(TextStats.size(maxEditorLineBytes)) cannot be edited in the editor."
}
