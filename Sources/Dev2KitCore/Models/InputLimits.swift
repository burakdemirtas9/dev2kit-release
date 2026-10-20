import Foundation

/// Uygulamadaki her metin alanının sınırı (kullanıcı kararı, 2026-10-18:
/// "tüm input alanları sınırlansın"). Kod editörlerininki ayrı:
/// `WorkbenchLimits`.
///
/// Neden: tek satırlık SwiftUI metin alanı yapıştırılan metni megabayt
/// başına ~1,7 sn'de yerleştiriyor (M4, release, ölçüldü); başlık değerine
/// 4 MB yapıştırmak uygulamayı dondurdu. Sınır metin alana GİRMEDEN uygulanır
/// (`inputLimit` değiştiricisi); sonradan kırpmak donmayı önlemiyordu.
///
/// Sayılar gerçek kullanıma göre: en büyük alan 64 KB (~110 ms yerleşim).
/// Başlık değeri 8 KB, 1000 değil: Authorization'daki JWT 1000 karakteri
/// kolayca aşar; sunucuların çoğu başlık başına 8 KB kabul eder.
public enum InputLimits {
    public enum Field: Sendable {
        /// İstek, koleksiyon, environment, profil adları.
        case name
        /// Arama kutuları.
        case search
        /// İstek adresi, sunucu/gateway adresleri. Sunucuların istek satırı
        /// sınırı çoğunlukla 8 KB.
        case url
        /// Başlık, parametre, form alanı ve değişken ADI.
        case key
        /// Başlık ve sorgu parametresi DEĞERİ.
        case headerValue
        /// Form alanı değeri.
        case formValue
        /// Bearer/API key/JWT gibi token alanları.
        case token
        /// Kullanıcı adı, parola, client id/secret, scope.
        case credential
        /// Environment değişkeni ve secret değeri (PEM sertifika sığsın).
        case secretValue
        /// Dosya yolu.
        case path
        /// Workbench ağacında yaprak değeri.
        case treeValue
        /// Kısa teknik alan: XML kök adı, yanıt alanı yolu, değişken adı.
        case short

        public var maxCharacters: Int {
            switch self {
            case .name: return 200
            case .search, .key, .short: return 256
            case .credential: return 1_024
            case .path: return 4_096
            case .url, .headerValue: return 8_192
            case .token: return 16_384
            case .formValue, .secretValue, .treeValue: return 65_536
            }
        }
    }

    /// Başlık, parametre, form alanı ve environment değişkeni satır sayısı.
    public static let maxRows = 1_000

    /// Toplu düzenleme metni: satır başına bir kayıt.
    public static let maxBulkLines = maxRows
    public static let maxBulkBytes = 1_000_000

    /// İçe aktarma editörleri (OpenAPI, Kibana JSON): büyük spesifikasyonlar
    /// 16.000 satırı kolayca aşar; gösterilen çıktıyla aynı tavan.
    public static let maxImportBytes = ImportReviewer.maxImportBytes
    public static let maxImportLines = 1_000_000

    /// Editör kapısını atlayan yollar ("Panodan Yapıştır", dosya okuma) için
    /// aynı denetim: aşıyorsa açıklama, yoksa `nil`.
    public static func rejection(of text: String, maxBytes: Int, maxLines: Int) -> String? {
        let bytes = text.utf8.count
        if bytes > maxBytes {
            return L10n.t("limits.textTooLarge", TextStats.size(bytes), TextStats.size(maxBytes))
        }
        let lines = TextStats.lineCount(text)
        if lines > maxLines {
            return L10n.t("limits.textTooManyLines", L10n.number(lines), L10n.number(maxLines))
        }
        return nil
    }

    public static func tooLongMessage(_ field: Field) -> String {
        L10n.t("limits.fieldTooLong", L10n.number(field.maxCharacters))
    }

    public static var tooManyRowsMessage: String {
        L10n.t("limits.tooManyRows", L10n.number(maxRows))
    }
}
