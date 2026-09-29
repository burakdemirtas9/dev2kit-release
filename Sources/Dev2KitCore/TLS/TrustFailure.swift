import Foundation
import Security

/// Güven değerlendirmesinde HANGİ kontrollerin düştüğü.
///
/// Neden gerekli: Apple, 1 Eylül 2020'den sonra düzenlenmiş TLS sunucu
/// sertifikalarında 398 günden uzun geçerlilik kabul etmiyor. Kural public
/// WebPKI için konmuş; kendi kontrolündeki test/kurum PKI'sında uzun ömürlü
/// sertifika yaygın ve meşru. Apple'ın kendisi de sisteme kurulmuş köklere
/// muafiyet tanıyor — ama bu muafiyet, çıpaları programatik verdiğimiz yola
/// uygulanmıyor (ölçüldü).
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
            (hostnameKey, "sertifikadaki adlar bu host ile eşleşmiyor"),
            (temporalValidityKey, "sertifikanın tarihleri geçerli değil (süresi dolmuş ya da henüz başlamamış)"),
            (validityPeriodKey, "sunucu sertifikasının geçerlilik süresi Apple'ın izin verdiği "
                + "üst sınırı (398 gün) aşıyor. Kurum kökünün süresi uzun olabilir; "
                + "sınır yalnızca sunucu sertifikasına uygulanır"),
        ]
        var parts = known.filter { checks.contains($0.0) }.map(\.1)
        let others = checks.subtracting(known.map(\.0))
        if !others.isEmpty {
            parts.append("başka kontroller düştü (\(others.sorted().joined(separator: ", ")))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    public static func isOnlyValidityPeriodLimit(_ trust: SecTrust) -> Bool {
        let details = details(of: trust)
        guard !details.isEmpty else { return false }
        return isOnlyValidityPeriodLimit(details)
    }
}
