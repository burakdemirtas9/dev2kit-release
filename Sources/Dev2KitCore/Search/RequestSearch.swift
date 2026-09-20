import Foundation

/// Sidebar aramasının kuralları.
///
/// Neden Core'da: "eşleşme" tanımı (birden fazla kelime nasıl yorumlanır,
/// Türkçe büyük/küçük harf, hangi alanlar taranır) davranışsal mantıktır ve
/// test edilmesi gerekir. View içinde kalırsa test edilemez.
///
/// Taranan alanlar: istek adı, HTTP metodu, URL ve koleksiyon adı.
/// Header/body/auth içerikleri KASITLI olarak taranmaz: gürültü yaratır ve
/// secret referanslarını arama davranışına taşır.
public enum RequestSearch {
    /// Bir koleksiyonun sorguya göre gösterilecek hali.
    public struct Match: Identifiable, Sendable, Equatable {
        /// Kaynak koleksiyon; başlık, yeniden adlandırma, dışa aktarma ve
        /// silme akışları koleksiyonun kendisine ihtiyaç duyuyor.
        public let collection: CollectionModel
        /// Sorguyla eşleşen istekler. Sorgu boşsa koleksiyonun tüm istekleri.
        public let requests: [RequestModel]

        public var id: UUID { collection.id }

        public init(collection: CollectionModel, requests: [RequestModel]) {
            self.collection = collection
            self.requests = requests
        }
    }

    /// Sorguyu parçalara böler. Boşluk ayırıcıdır ve her parça ayrı ayrı
    /// eşleşmek zorundadır: "post user" → hem "post" hem "user" içeren istek.
    /// Yalnızca boşluktan oluşan sorgu, arama yapılmıyor sayılır.
    public static func tokens(from query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Koleksiyonları sorguya göre filtreler.
    ///
    /// - Sorgu boşsa liste aynen döner; böylece view'da "filtreli/filtresiz"
    ///   diye iki kod yolu olmaz.
    /// - Koleksiyon adı da taranan metnin parçası olduğu için koleksiyon adına
    ///   yazınca içindeki tüm istekler kalır ("kullanici get" gibi karışık
    ///   sorgular da çalışır).
    /// - Eşleşen isteği kalmayan koleksiyon listeden düşer. Tek istisna: adı
    ///   eşleşen BOŞ koleksiyon, kullanıcı "koleksiyonum kaybolmuş" sanmasın
    ///   diye boş olarak gösterilir.
    public static func filter(_ collections: [CollectionModel], query: String) -> [Match] {
        let needles = tokens(from: query).map(fold)
        guard !needles.isEmpty else {
            return collections.map { Match(collection: $0, requests: $0.requests) }
        }
        return collections.compactMap { collection in
            let hits = collection.requests.filter {
                contains(haystack($0, collectionName: collection.name), needles)
            }
            if hits.isEmpty {
                // Buraya yalnızca istek listesi boş olan koleksiyonlar düşer:
                // koleksiyon adı eşleşiyorsa her isteği de eşleşirdi.
                return contains(collection.name, needles) ? Match(collection: collection, requests: []) : nil
            }
            return Match(collection: collection, requests: hits)
        }
    }

    /// Tek bir isteğin sorguya uyup uymadığı. Boş sorgu her isteğe uyar.
    public static func matches(
        _ request: RequestModel,
        collectionName: String = "",
        tokens: [String]
    ) -> Bool {
        guard !tokens.isEmpty else { return true }
        return contains(haystack(request, collectionName: collectionName), tokens.map(fold))
    }

    /// Sonuçtaki toplam istek sayısı — arama alanındaki "N eşleşme" göstergesi.
    public static func totalRequests(in matches: [Match]) -> Int {
        matches.reduce(0) { $0 + $1.requests.count }
    }

    // MARK: - Eşleşme ayrıntıları

    /// Bir isteğin aranabilir metni. Tek bir metin kuruluyor ki parça başına
    /// tek karşılaştırma yetsin: liste her tuş vuruşunda yeniden filtreleniyor.
    private static func haystack(_ request: RequestModel, collectionName: String) -> String {
        "\(request.name) \(request.method.rawValue) \(request.url) \(collectionName)"
    }

    /// `needles` ÖNCEDEN katlanmış olmalı (bkz. `fold`); sorgu parçaları
    /// istek başına yeniden katlanmasın diye çağıran tarafta bir kez yapılıyor.
    private static func contains(_ text: String, _ needles: [String]) -> Bool {
        let haystack = fold(text)
        return needles.allSatisfy { haystack.contains($0) }
    }

    /// Karşılaştırma için metni sadeleştirir: büyük/küçük harf, aksan ve
    /// tam/yarım genişlik farkları silinir, sonra noktasız `ı` noktalı `i`ye
    /// eşitlenir.
    ///
    /// Neden `localizedStandardContains` kullanılmıyor: sistem yerel ayarı
    /// tr_TR olduğunda Türkçe harf kuralları arama alanında ters etki yapıyor —
    /// "LISTELE" ile "Listele", "iptal" ile "İptal" eşleşmiyor (I→ı, İ→i).
    /// Arama kutusunda kullanıcı klavyesinde ne varsa onu yazar; bu yüzden
    /// eşleşme yerel ayardan bağımsız ve öngörülebilir tutuluyor. Yan fayda:
    /// sonuç makineden makineye değişmiyor, test edilebiliyor.
    private static func fold(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: foldLocale
        )
        // `ı` Unicode'da `i`nin aksanlı hali değil, ayrı bir harf; katlama onu
        // dönüştürmüyor. Elle eşitlenmezse "kullanicilar" yazan kullanıcı
        // "Kullanıcılar" koleksiyonunu bulamıyor.
        .replacingOccurrences(of: "ı", with: "i")
    }

    /// Katlama yerel ayarı sabit: Türkçe locale'de `.caseInsensitive` I harfini
    /// noktasız ı yapar ve aramayı yine bozar.
    private static let foldLocale = Locale(identifier: "en_US_POSIX")
}
