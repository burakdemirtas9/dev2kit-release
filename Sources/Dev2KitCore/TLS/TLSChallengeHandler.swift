import Foundation
import Security

/// İsteğe uygulanacak, dosyadan yüklenmiş TLS malzemesi.
///
/// Yükleme istek gönderilmeden ÖNCE yapılır: dosya yoksa ya da parola
/// yanlışsa kullanıcı anlaşılır bir hata görür, anlamsız bir TLS el sıkışma
/// hatası değil.
public struct ResolvedTLSProfile: @unchecked Sendable {
    public let caCertificates: [SecCertificate]
    /// Yalnızca bu CA kabul edilsin mi (sertifika sabitleme).
    public let pinToCA: Bool
    /// Ömür üst sınırı (398 gün) bu host'ta aranmasın mı.
    public let allowLongValidity: Bool
    public let identity: SecIdentity?

    public init(
        caCertificates: [SecCertificate],
        pinToCA: Bool,
        allowLongValidity: Bool = false,
        identity: SecIdentity?
    ) {
        self.caCertificates = caCertificates
        self.pinToCA = pinToCA
        self.allowLongValidity = allowLongValidity
        self.identity = identity
    }

    public var isEmpty: Bool { caCertificates.isEmpty && identity == nil }
}

/// TLS kimlik doğrulama challenge'larını karşılar.
///
/// **Burada "hepsini kabul et" yolu YOKTUR ve olmamalıdır.** Sertifika
/// doğrulamasını atlayan bir kısayol (`URLCredential(trust:)` doğrudan dönmek),
/// özelliği hiç eklememekten daha kötüdür: kullanıcı güvende sanırken değildir.
/// Kurum CA'sı yalnızca EK GÜVEN ÇIPASI olarak eklenir, doğrulamanın kendisi
/// her zaman çalışır ve sonucuna uyulur.
enum TLSChallengeHandler {
    /// Bağlantının neden reddedildiği. `nil` ise reddedilmedi.
    ///
    /// Bunu taşımak ŞART: URLSession, `cancelAuthenticationChallenge`'ı
    /// `-999 cancelled` olarak raporluyor — yani kullanıcının isteği iptal
    /// etmesiyle AYNI kod. Sebep taşınmazsa güvenlik gerekçeli bir reddi
    /// "kullanıcı vazgeçti" sanıp sessizce yutuyoruz; kullanıcı ekranda ne
    /// hata ne yanıt görüyor. (Sahada tam olarak bu yaşandı.)
    struct Rejection: Equatable, Sendable {
        let host: String
        /// Bizim reddimizin gerekçesi. Sistem reddettiğinde boş olur —
        /// o durumda karar bizim değil, elimizde yalnızca künye var.
        let reason: String
        /// Sunucunun sunduğu sertifikanın geçerli olduğu adlar.
        let presentedNames: String?

        init(host: String, reason: String, presentedNames: String? = nil) {
            self.host = host
            self.reason = reason
            self.presentedNames = presentedNames
        }

        /// Bağlantıyı biz mi reddettik.
        var isOurs: Bool { !reason.isEmpty }
    }

    /// Sunucu sertifikası doğrulaması.
    static func serverTrust(
        challenge: URLAuthenticationChallenge,
        profile: ResolvedTLSProfile?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?, Rejection?) {
        let host = challenge.protectionSpace.host
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.cancelAuthenticationChallenge, nil, Rejection(
                host: host,
                reason: "Sunucu bir sertifika sunmadı."
            ))
        }
        // Profil yoksa sistem davranışı: sistem kök sertifikalarıyla doğrula.
        //
        // Karar sistemde kalıyor ama sunucunun sertifikasının hangi adlar için
        // geçerli olduğunu ŞİMDİ okuyoruz: sistem reddederse elimizde yalnızca
        // "sertifika geçersiz" gibi bir cümle kalıyor ve kullanıcı neyi
        // düzelteceğini bilemiyor. Maliyeti bir SAN okuması; güven
        // değerlendirmesi tekrarlanmıyor.
        guard let profile, !profile.caCertificates.isEmpty else {
            return (.performDefaultHandling, nil, presentedNames(of: trust).map {
                Rejection(host: host, reason: "", presentedNames: $0)
            })
        }

        // Politikayı host ile birlikte kur: hostname doğrulaması korunur.
        // Bunu atlamak, geçerli ama BAŞKA bir host'a ait sertifikayı kabul
        // etmek demek olurdu.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, profile.caCertificates as CFArray) == errSecSuccess,
              // false: kurum CA'sı sistem köklerine EK olarak geçerli.
              // true: yalnızca bu CA (sabitleme).
              SecTrustSetAnchorCertificatesOnly(trust, profile.pinToCA) == errSecSuccess else {
            return (.cancelAuthenticationChallenge, nil, Rejection(
                host: host,
                reason: "Güven değerlendirmesi kurulamadı (sertifika çıpaları uygulanamadı)."
            ))
        }

        var error: CFError?
        // Değerlendirme sonucuna UYULUR. Başarısızsa bağlantı reddedilir.
        guard SecTrustEvaluateWithError(trust, &error) else {
            // Tek istisna: kullanıcı bu host'lar için ömür sınırını açıkça
            // muaf tuttuysa ve düşen TEK kontrol o sınırsa. Zincir, imza,
            // tarihler ve hostname yine geçmiş olmak zorunda; bunlardan biri
            // bile düşmüşse buraya girilmez (bkz. `TrustFailure`).
            if profile.allowLongValidity, TrustFailure.isOnlyValidityPeriodLimit(trust) {
                return (.useCredential, URLCredential(trust: trust), nil)
            }
            // Sistemin gerekçesi kullanıcıya AYNEN aktarılır: "kök bulunamadı"
            // ile "ad eşleşmiyor" tamamen farklı çözümler gerektiriyor.
            // Gerekçe önce düşen kontrollerden üretilir; sistem kodu tek bir
            // sebep verdiği için yanıltabiliyor (ölçüldü: hostname'i yanlış
            // olan uzun ömürlü sertifikada kod yine süre sınırını gösteriyor).
            let checks = TrustFailure.failedChecks(in: TrustFailure.details(of: trust))
            let names = presentedNames(of: trust)
            var reason = TrustFailure.describe(checks) ?? explain(error)
            // Ad uyuşmazlığında asıl soru "peki sertifikada hangi adlar var".
            if checks.contains(TrustFailure.hostnameKey), let names {
                reason += " — sunucunun GÖNDERDİĞİ sertifika şu adlar için geçerli: \(names)"
            }
            return (.cancelAuthenticationChallenge, nil, Rejection(
                host: host, reason: reason, presentedNames: names
            ))
        }
        return (.useCredential, URLCredential(trust: trust), nil)
    }

    /// Güven değerlendirmesinin gerekçesi, anlaşılır haliyle.
    ///
    /// Sistemin bazı mesajları kullanıcıya hiçbir şey söylemiyor; en sık
    /// rastlanan ve en kafa karıştıranı geçerlilik süresi sınırı. Apple,
    /// 1 Eylül 2020'den sonra düzenlenmiş SUNUCU sertifikalarında 398 günden
    /// uzun geçerlilik kabul etmiyor ve hatayı "standartlarla uyumlu değil"
    /// diye veriyor. Ölçüldü: aynı kurum köküyle imzalanmış 300 günlük
    /// sertifika geçiyor, 10 yıllık `-67901` ile düşüyor. Kökün kendi süresi
    /// uzun olabilir, kural yalnızca uç sertifikaya uygulanıyor.
    static func explain(_ error: CFError?) -> String {
        let fallback = "sertifika zinciri doğrulanamadı"
        guard let error = error as Error? as NSError? else { return fallback }
        if error.domain == NSOSStatusErrorDomain,
           error.code == Int(errSecCertificateValidityPeriodTooLong) {
            return "sunucu sertifikasının geçerlilik süresi Apple'ın izin verdiği "
                + "üst sınırı (398 gün) aşıyor. Kurum kökünün süresi uzun olabilir; "
                + "sınır yalnızca sunucu sertifikasına uygulanır."
        }
        return error.localizedDescription.isEmpty ? fallback : error.localizedDescription
    }

    /// Sunucunun EL SIKIŞMADA GÖNDERDİĞİ sertifikanın künyesi: geçerli
    /// olduğu adlar ve onu düzenleyen.
    ///
    /// Düzenleyen de yazılıyor çünkü kullanıcı bu adları kendi güven
    /// deposuna koyduğu sertifikadan sanabiliyor. Düzenleyen public bir CA
    /// ise ("DigiCert", "GlobalSign"…) karşıdaki makinenin iç servis değil
    /// internete açık bir sunucu olduğu tek bakışta anlaşılıyor — sahada tam
    /// olarak bu oldu.
    private static func presentedNames(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        let names = CertificateLoader.subjectNames(of: leaf)
        guard !names.isEmpty else { return nil }
        // Uzun listelerde mesaj okunmaz hale gelmesin.
        let shown = names.prefix(8).joined(separator: ", ")
        var summary = names.count > 8 ? "\(shown) (+\(names.count - 8) tane daha)" : shown
        if let issuer = CertificateLoader.details(of: leaf).issuerCommonName {
            summary += " · düzenleyen: \(issuer)"
        }
        return summary
    }

    /// İstemci sertifikası (mTLS) sunumu.
    static func clientCertificate(
        profile: ResolvedTLSProfile?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Kimlik yalnızca profili eşleşen host'lara sunulur; istemci
        // sertifikası kim olduğunu ifşa eder, her sunucuya gönderilmez.
        guard let identity = profile?.identity else {
            // Sunucu istemci sertifikası istiyor ama tanımlı değil: sertifikasız
            // devam edilir ve sunucu reddederse kullanıcı bunu görür.
            return (.performDefaultHandling, nil)
        }
        let credential = URLCredential(
            identity: identity,
            certificates: nil,
            persistence: .forSession
        )
        return (.useCredential, credential)
    }
}
