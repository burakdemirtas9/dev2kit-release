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
    /// Ömür üst sınırı bu host'ta aranmasın mı (host profili seçeneği).
    public let allowLongValidity: Bool
    /// Zinciri bunlardan birine çıkan sertifikalarda ömür üst sınırı aranmaz.
    /// Güven deposundaki CA'lar; kullanıcı Güven Deposu'nda açıkça seçtiyse.
    public let longValidityAnchors: [SecCertificate]
    /// Sunucu sertifikası HİÇ doğrulanmasın mı (uygulama geneli kaçış kapısı,
    /// bkz. `RequestEngine.skipCertificateValidation`).
    public let skipValidation: Bool
    public let identity: SecIdentity?

    public init(
        caCertificates: [SecCertificate],
        pinToCA: Bool,
        allowLongValidity: Bool = false,
        longValidityAnchors: [SecCertificate] = [],
        skipValidation: Bool = false,
        identity: SecIdentity?
    ) {
        self.caCertificates = caCertificates
        self.pinToCA = pinToCA
        self.allowLongValidity = allowLongValidity
        self.longValidityAnchors = longValidityAnchors
        self.skipValidation = skipValidation
        self.identity = identity
    }

    public var isEmpty: Bool { caCertificates.isEmpty && identity == nil && !skipValidation }
}

// TODO(showcase): geçici kaçış kapısı. İleride host bazlı hale getirilecek
// ya da tamamen kaldırılacak — bkz. TODO.md "Sertifika doğrulama anahtarı".

/// TLS kimlik doğrulama challenge'larını karşılar.
///
/// Kurum CA'sı yalnızca EK GÜVEN ÇIPASI olarak eklenir, doğrulamanın kendisi
/// çalışır ve sonucuna uyulur.
///
/// TEK İSTİSNA: kullanıcının uygulama genelinde açtığı "doğrulamayı kapat"
/// anahtarı (`ResolvedTLSProfile.skipValidation`). Sessiz bir kısayol değil:
/// açıkken araç çubuğunda ve her yanıtta görünür bir uyarı var, açılışta
/// her zaman kapalı başlar. Bunun dışında "hepsini kabul et" yolu yoktur.
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
                reason: L10n.t("trust.noCertificate")
            ))
        }
        // KAÇIŞ KAPISI: kullanıcı doğrulamayı kapattı. Değerlendirme hiç
        // yapılmıyor; yanıttaki iz `ResponseData.certificateValidationSkipped`.
        if profile?.skipValidation == true {
            return (.useCredential, URLCredential(trust: trust), nil)
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
                reason: L10n.t("trust.setupFailed")
            ))
        }

        var error: CFError?
        // Değerlendirme sonucuna UYULUR. Başarısızsa bağlantı reddedilir.
        guard SecTrustEvaluateWithError(trust, &error) else {
            // Tek istisna: düşen TEK kontrol ömür sınırıysa ve kullanıcı bunu
            // açıkça muaf tuttuysa — ya bu host'lar için (profil) ya da zinciri
            // güven deposundaki bir CA'ya çıkan sertifikalar için. Zincir,
            // imza, tarihler ve hostname yine geçmiş olmak zorunda; bunlardan
            // biri bile düşmüşse buraya girilmez (bkz. `TrustFailure`).
            if TrustFailure.isOnlyValidityPeriodLimit(trust),
               profile.allowLongValidity
                || TrustFailure.chain(of: trust, endsAtOneOf: profile.longValidityAnchors) {
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
                reason += L10n.t("trust.presentedNames", names)
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
    /// rastlanan ve en kafa karıştıranı geçerlilik süresi sınırı. Apple
    /// SUNUCU sertifikalarına ömür üst sınırı koyuyor ve hatayı "standartlarla
    /// uyumlu değil" diye veriyor. Ölçüldü: bizim verdiğimiz kurum köküyle
    /// imzalı sertifikada sınır 825 gün (825 geçiyor, 826 `-67901` ile
    /// düşüyor); public köklerde 398. Kökün kendi süresi uzun olabilir, kural
    /// yalnızca uç sertifikaya uygulanıyor.
    static func explain(_ error: CFError?) -> String {
        let fallback = L10n.t("trust.chainFailed")
        guard let error = error as Error? as NSError? else { return fallback }
        if error.domain == NSOSStatusErrorDomain,
           error.code == Int(errSecCertificateValidityPeriodTooLong) {
            return L10n.t("trust.check.validityPeriod") + "."
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
        var summary = names.count > 8 ? L10n.t("trust.moreNames", shown, L10n.number(names.count - 8)) : shown
        if let issuer = CertificateLoader.details(of: leaf).issuerCommonName {
            summary += L10n.t("trust.issuer", issuer)
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
