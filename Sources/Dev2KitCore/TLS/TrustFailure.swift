import Foundation
import Security

/// Güven değerlendirmesinde HANGİ kontrollerin düştüğü.
///
/// Neden gerekli: Apple TLS sunucu sertifikalarına ömür üst sınırı koyuyor.
/// Ölçüldü (macOS 26/27, çıpayı `SecTrustSetAnchorCertificates` ile
/// verdiğimiz yol): bizim verdiğimiz kurum CA'larıyla imzalı sertifikada
/// sınır **825 gün** — 825 geçiyor, 826 düşüyor. Public köklerdeki 398 gün
/// kuralı buraya uygulanmıyor. Kendi kontrolündeki kurum PKI'sında daha uzun
/// ömürlü sertifika yine de yaygın (AD CS şablonları 3-5 yıl basabiliyor).
///
/// Hata KODUNA bakarak "yalnızca süre sorunu var" denemez: ölçüldü, hostname'i
/// de yanlış olan 10 yıllık sertifika yine `-67901` veriyor. `SecTrustCopyResult`
/// ise düşen kontrolleri tek tek veriyor, o yüzden karar buna dayanıyor.
public enum TrustFailure {
    /// Geçerlilik süresi üst sınırı.
    public static let validityPeriodKey = "OtherTrustValidityPeriod"
    /// Sertifika tarihleri (süresi dolmuş / henüz başlamamış).
    public static let temporalValidityKey = "TemporalValidity"
    /// Hostname eşleşmesi.
    public static let hostnameKey = "SSLHostname"

    /// Zincirdeki tüm sertifikalarda düşen kontrollerin adları.
    ///
    /// `StatusCodes` bir kontrol değil, sayısal karşılıkların listesi; ayıklanır.
    public static func failedChecks(in details: [[String: Any]]) -> Set<String> {
        var result: Set<String> = []
        for certificate in details {
            for key in certificate.keys where key != "StatusCodes" {
                result.insert(key)
            }
        }
        return result
    }

    /// Değerlendirme YALNIZCA geçerlilik süresi sınırına mı takıldı.
    ///
    /// Ölçülen gerçek değerler:
    /// - 10 yıllık, adı doğru  → `{OtherTrustValidityPeriod}`      → true
    /// - süresi dolmuş         → `{TemporalValidity}`               → false
    /// - 10 yıllık, adı yanlış → `{OtherTrustValidityPeriod, SSLHostname}` → false
    ///
    /// Yani zincir, imza, tarihler, hostname ve diğer her kontrol eskisi gibi
    /// zorunlu kalıyor; gevşeyen tek şey ömür üst sınırı.
    public static func isOnlyValidityPeriodLimit(_ details: [[String: Any]]) -> Bool {
        failedChecks(in: details) == [validityPeriodKey]
    }

    /// `SecTrust`ten düşen kontrolleri okur. Okunamazsa boş döner — boş küme
    /// "yalnızca süre" sayılmaz, yani bilinmeyen durumda KABUL EDİLMEZ.
    public static func details(of trust: SecTrust) -> [[String: Any]] {
        guard let result = SecTrustCopyResult(trust) as? [String: Any],
              let details = result["TrustResultDetails"] as? [[String: Any]]
        else { return [] }
        return details
    }

    /// Düşen kontrollerin okunabilir karşılıkları.
    ///
    /// Sistem hata KODU tek bir sebep veriyor ve yanıltabiliyor: hostname'i
    /// de yanlış olan uzun ömürlü sertifikada kod yine `-67901` (süre sınırı)
    /// çıkıyor, oysa asıl engel ad uyuşmazlığı. Elimizde kontrol listesi
    /// varken koda güvenmiyoruz.
    public static func describe(_ checks: Set<String>) -> String? {
        guard !checks.isEmpty else { return nil }
        // Sıra sabit: kullanıcı aynı durumda hep aynı metni görsün.
        let known: [(String, String)] = [
            (hostnameKey, L10n.t("trust.check.hostname")),
            (temporalValidityKey, L10n.t("trust.check.dates")),
            (validityPeriodKey, L10n.t("trust.check.validityPeriod")),
        ]
        var parts = known.filter { checks.contains($0.0) }.map(\.1)
        let others = checks.subtracting(known.map(\.0))
        if !others.isEmpty {
            parts.append(L10n.t("trust.check.others", others.sorted().joined(separator: ", ")))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Değerlendirilen zincir verilen çıpalardan birinde mi bitiyor.
    ///
    /// Ömür muafiyetini yalnızca kullanıcının açıkça güvendiği CA'lara
    /// bağlamak için: zincir public bir köke çıkıyorsa muafiyet uygulanmaz.
    /// Ölçüldü: değerlendirme yalnızca ömür sınırından düştüğünde zincir
    /// çıpaya kadar kurulmuş halde geliyor; tanınmayan CA'da ise zincir
    /// yalnızca uç sertifikadan ibaret, yani yanlışlıkla eşleşemez.
    /// Karşılaştırma DER baytlarıyla yapılır: ad aynı ama anahtar farklı bir
    /// sertifika eşleşmez.
    public static func chain(_ chain: [SecCertificate], endsAtOneOf anchors: [SecCertificate]) -> Bool {
        guard let last = chain.last, !anchors.isEmpty else { return false }
        let lastData = SecCertificateCopyData(last) as Data
        return anchors.contains { SecCertificateCopyData($0) as Data == lastData }
    }

    public static func chain(of trust: SecTrust, endsAtOneOf anchors: [SecCertificate]) -> Bool {
        let built = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        return chain(built, endsAtOneOf: anchors)
    }

    public static func isOnlyValidityPeriodLimit(_ trust: SecTrust) -> Bool {
        let details = details(of: trust)
        guard !details.isEmpty else { return false }
        return isOnlyValidityPeriodLimit(details)
    }
}
