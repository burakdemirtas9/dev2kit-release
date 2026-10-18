import Foundation

/// Workbench ve Diff Checker girdi/çıktı sınırları (docs/V2.md "Sınırlar").
///
/// Ölçüm (M4, release, 2026-10-18, ana thread'in en uzun donması):
/// - Çok satırlı metin editörde doğrusal: 5 MB 0,3 sn, 20 MB 1,0 sn.
/// - TEK satırlı metin (sıkıştırılmış JSON) macOS metin yerleştiricisinde
///   pahalı: 2 MB 1,05 sn, 5 MB 2,6 sn — satır baştan sona yerleşmek zorunda.
///
/// Kullanıcı kararı (2026-10-18): girdi başına 4 MB (önce 20 MB seçildi,
/// "ihtiyaca göre ileride artırılır" diyerek düşürüldü); 1 MB'tan uzun satır
/// editörde gösterilmez. İkisinde de kullanıcı açıkça bilgilendirilir.
public enum WorkbenchLimits {
    /// Bir girdinin (ve editörde gösterilen bir çıktının) üst sınırı.
    /// Ondalık: boyutlar arayüzde 1000 tabanlı gösteriliyor (`TextStats.size`,
    /// Finder gibi); 1024 tabanlı sınır mesajda "21 MB" görünüyordu.
    public static let maxInputBytes = 4_000_000
    /// Editörde gösterilen çıktının üst sınırı. Girdiden AYRI: sıkıştırılmış
    /// 3 MB JSON biçimlenince satır sonu ve girintiyle 4 MB'ı aşıyor; aynı
    /// sınır Workbench'in asıl işini (yapıştır → Format) bozuyordu. Çok satırlı
    /// 20 MB editörde ~1 sn (ölçüldü). Çıktıyı düzenlemek ve girdi yapmak
    /// girdiye yazdığı için onlar `maxInputBytes`'a tabi.
    public static let maxOutputBytes = 20_000_000
    /// Bir girdinin en çok satır sayısı (kullanıcı kararı, 2026-10-18).
    /// Aşacak değişiklik (Enter, yapıştırma, sürükleme) yapılmaz; sınıra
    /// ulaşmış metne HİÇBİR ekleme yapılmaz (satır sonu içermeyen yazım da):
    /// ilk sürümde yalnız yeni satır engelleniyordu, kullanıcı aynı satıra
    /// binlerce ekleme yapabildi. Silmek ve büyütmeyen değiştirme serbest. Gösterilen
    /// çıktıya uygulanmaz (biçimlenmiş JSON kolayca aşar); çıktıyı düzenlemek
    /// ve girdi yapmak girdiye yazdığı için uygulanır.
    public static let maxInputLines = 16_000
    /// Editörde gösterilebilecek en uzun satır. Kullanıcı kararıyla 2 MB'tan
    /// 1 MB'a indi (2026-10-18); tek satır 1 MB editörde ~0,5 sn.
    public static let maxEditorLineBytes = 1_000_000
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
    public static func isTooLargeForEditor(_ text: String, maxBytes: Int = maxInputBytes) -> Bool {
        text.utf8.count > maxBytes || hasLine(longerThan: maxEditorLineBytes, in: text)
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

    public static let atLineLimitMessage =
        "Not added: the input is at the \(grouped(maxInputLines))-line limit. Delete something first."

    public static func tooManyLinesMessage(lines: Int) -> String {
        "Not added: the result would have \(grouped(lines)) lines. The limit is \(grouped(maxInputLines)) lines per input."
    }

    /// Çıktı girdi sınırlarını (boyut ya da satır) aşıyorsa açıklama; aşmıyorsa `nil`.
    public static func outputEditIssue(_ output: String) -> String? {
        let bytes = output.utf8.count
        let lines = TextStats.lineCount(output)
        guard bytes > maxInputBytes || lines > maxInputLines else { return nil }
        return "Output is \(TextStats.size(bytes)), \(grouped(lines)) lines: it can be copied, but editing it or using it as input is limited to \(TextStats.size(maxInputBytes)) and \(grouped(maxInputLines)) lines (edits flow into the input)."
    }

    static func grouped(_ value: Int) -> String {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.locale = Locale(identifier: "en_US")
        return number.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static let longLineEditMessage =
        "Not added: lines longer than \(TextStats.size(maxEditorLineBytes)) cannot be edited in the editor."
}
