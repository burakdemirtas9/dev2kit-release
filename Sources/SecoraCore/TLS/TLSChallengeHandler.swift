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
    public let identity: SecIdentity?

    public init(caCertificates: [SecCertificate], pinToCA: Bool, identity: SecIdentity?) {
        self.caCertificates = caCertificates
        self.pinToCA = pinToCA
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
    /// Sunucu sertifikası doğrulaması.
    static func serverTrust(
        challenge: URLAuthenticationChallenge,
        profile: ResolvedTLSProfile?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.cancelAuthenticationChallenge, nil)
        }
        // Profil yoksa sistem davranışı: sistem kök sertifikalarıyla doğrula.
        guard let profile, !profile.caCertificates.isEmpty else {
            return (.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host
        // Politikayı host ile birlikte kur: hostname doğrulaması korunur.
        // Bunu atlamak, geçerli ama BAŞKA bir host'a ait sertifikayı kabul
        // etmek demek olurdu.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, profile.caCertificates as CFArray) == errSecSuccess,
              // false: kurum CA'sı sistem köklerine EK olarak geçerli.
              // true: yalnızca bu CA (sabitleme).
              SecTrustSetAnchorCertificatesOnly(trust, profile.pinToCA) == errSecSuccess else {
            return (.cancelAuthenticationChallenge, nil)
        }

        var error: CFError?
        // Değerlendirme sonucuna UYULUR. Başarısızsa bağlantı reddedilir.
        guard SecTrustEvaluateWithError(trust, &error) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
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
