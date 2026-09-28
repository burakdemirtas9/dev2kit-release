import Foundation

/// Editörlerde metin arama kuralları.
///
/// Neden Core'da: "hangi eşleşmeler var, imleçten sonraki eşleşme hangisi,
/// sonuncudan sonra nereye sarılır" sorularının cevabı davranıştır. İstek
/// gövdesi ve yanıt editörü bunları AYNI şekilde uygular; arayüz yalnızca
/// çizer ve gezinir.
///
/// Paylaşılan şey DURUM değil KURALdır: iki editörün her birinin kendi
/// sorgusu, kendi seçenekleri ve kendi eşleşme imleci vardır (bkz.
/// `EditorSearchController`). Buradaki tipler değer tipi ve saf fonksiyon
/// olduğu için ikisi birbirini etkilemez.
public enum TextSearch {
    public struct Options: Equatable, Sendable {
        /// Kapalıyken büyük/küçük harf ayrımı yapılmaz (varsayılan): aranan
        /// şey çoğu zaman bir alan adı ve kullanıcı harf durumunu bilmez.
        public var caseSensitive: Bool
        /// Açıkken sorgu düzenli ifade olarak yorumlanır.
        public var isRegex: Bool

        public init(caseSensitive: Bool = false, isRegex: Bool = false) {
            self.caseSensitive = caseSensitive
            self.isRegex = isRegex
        }
    }

    public struct Result: Equatable, Sendable {
        /// Metindeki eşleşmeler, baştan sona sıralı ve çakışmasız.
        public let ranges: [NSRange]
        /// `matchLimit`'e takıldı mı — arayüz sayıyı "2000+" diye gösterir ki
        /// kullanıcı eksik listeye tam sanıp güvenmesin.
        public let isTruncated: Bool
        /// Yalnızca regex kipinde, kalıp derlenemediğinde doğru olur.
        /// Mesajın kendisi arayüzde: Core kullanıcıya metin üretmez.
        public let isInvalidPattern: Bool

        public static let none = Result(ranges: [], isTruncated: false, isInvalidPattern: false)

        public var count: Int { ranges.count }
        public var isEmpty: Bool { ranges.isEmpty }

        public init(ranges: [NSRange], isTruncated: Bool, isInvalidPattern: Bool) {
            self.ranges = ranges
            self.isTruncated = isTruncated
            self.isInvalidPattern = isInvalidPattern
        }
    }

    /// Eşleşme sayısının üst sınırı.
    ///
    /// 800 KB'lık bir yanıtta tek harf aramak yüz binlerce aralık üretir;
    /// bunları tutmanın ve boyamanın kullanıcıya faydası yok — ekranda zaten
    /// bir avuç satır var. Sınır hem belleği hem de gezinmeyi anlamlı tutuyor.
    public static let matchLimit = 2_000

    /// Metindeki tüm eşleşmeler. Sorgu boşsa sonuç boştur (hata değil).
    ///
    /// Sıfır uzunluklu eşleşmeler (regex'te `a*` gibi) atılır: ekranda
    /// boyanacak bir yerleri yok ve aralarında gezinmek anlamsız.
    public static func find(_ query: String, in text: String, options: Options = Options()) -> Result {
        guard !query.isEmpty, !text.isEmpty else { return .none }
        return options.isRegex
            ? regexMatches(query, in: text, options: options)
            : literalMatches(query, in: text, options: options)
    }

    private static func literalMatches(_ query: String, in text: String, options: Options) -> Result {
        let haystack = text as NSString
        // `.literal` bilinçli olarak YOK: kopyalanmış metinde "ö" ayrışmış
        // (o + birleşen aksan) gelebiliyor, literal karşılaştırma onu ıskalar.
        let compare: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
        var ranges: [NSRange] = []
        var start = 0

        while start < haystack.length {
            let remaining = NSRange(location: start, length: haystack.length - start)
            let found = haystack.range(of: query, options: compare, range: remaining)
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            if ranges.count >= matchLimit {
                return Result(ranges: ranges, isTruncated: true, isInvalidPattern: false)
            }
            // Çakışmasız ilerleme: bulunanın sonundan devam.
            start = found.location + found.length
        }
        return Result(ranges: ranges, isTruncated: false, isInvalidPattern: false)
    }

    private static func regexMatches(_ query: String, in text: String, options: Options) -> Result {
        let regexOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: query, options: regexOptions) else {
            // Kullanıcı kalıbı yazarken metin çoğu zaman yarımdır ("(" gibi);
            // bu bir hata durumu değil, "henüz arama yapılamıyor" durumudur.
            return Result(ranges: [], isTruncated: false, isInvalidPattern: true)
        }
        var ranges: [NSRange] = []
        var truncated = false
        let full = NSRange(location: 0, length: (text as NSString).length)
        regex.enumerateMatches(in: text, range: full) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            ranges.append(match.range)
            if ranges.count >= matchLimit {
                truncated = true
                stop.pointee = true
            }
        }
        return Result(ranges: ranges, isTruncated: truncated, isInvalidPattern: false)
    }

    /// Sonraki/önceki eşleşmenin indeksi. Uçlarda başa/sona sarar: arama
    /// kutusunda ⏎'ye basmayı bırakmak gerekmesin.
    public static func step(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        let next = forward ? current + 1 : current - 1
        return (next % count + count) % count
    }

    /// İmlecin bulunduğu yerden İLERİDEKİ ilk eşleşme; ileride yoksa baştaki.
    ///
    /// Yazarken eşleşme listesi her tuşta değişiyor. Her seferinde belgenin
    /// başına atlamak kullanıcının baktığı yeri kaybettiriyor; bu yüzden
    /// imlecin olduğu yerden devam edilir.
    public static func firstIndex(atOrAfter location: Int, in ranges: [NSRange]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        return ranges.firstIndex { $0.location >= location } ?? 0
    }
}
