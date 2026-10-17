import Foundation

/// Belirli host'lar için TLS ayarları: ek güven çıpası (kurum CA'sı) ve/veya
/// istemci sertifikası (mTLS).
///
/// Sertifika dosyaları dev2kit'ya kopyalanmaz; yalnızca yolları tutulur.
/// Özel anahtarın custodian'ı olmamak bilinçli bir karar: p12 senin diskinde
/// kalır, biz onu yalnızca istek anında belleğe alırız. Parola vault'a gider.
public struct TLSProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Bu profilin uygulanacağı host kalıpları (`api.firma.com`, `*.firma.com`).
    public var hostPatterns: [String]
    /// Ek güven çıpası olarak eklenecek CA sertifikası (PEM veya DER).
    public var caCertificatePath: String
    /// Açıksa YALNIZCA bu CA kabul edilir (sertifika sabitleme).
    /// Kapalıysa sistem kökleri de geçerli kalır — kurumsal proxy senaryosunda
    /// bazı host'lar proxy'den, bazıları doğrudan geldiği için varsayılan budur.
    public var pinToCA: Bool
    /// Bu host'larda sertifikanın ömür üst sınırı aranmasın (kurum CA'larında
    /// 825, public CA'larda 398 gün). Kurum CA'sı güven deposundaysa aynı
    /// muafiyet Güven Deposu'ndan host yazmadan da açılabilir.
    ///
    /// Yalnızca ömür sınırı gevşer; zincir, imza, tarihler ve hostname
    /// kontrolleri aynen zorunlu kalır (bkz. `TrustFailure`). Host'a bağlı
    /// olması bilinçli: kural public WebPKI için var, kendi PKI'nda meşru
    /// olan şey internetin tamamı için meşru değil.
    public var allowLongValidity: Bool
    /// İstemci kimliği (.p12 / .pfx) dosya yolu.
    public var clientCertificatePath: String
    /// p12 parolası. `{{secret:isim}}` referansı kabul eder.
    public var clientCertificatePassword: String

    public init(
        id: UUID = UUID(),
        name: String = "Yeni Profil",
        hostPatterns: [String] = [],
        caCertificatePath: String = "",
        pinToCA: Bool = false,
        allowLongValidity: Bool = false,
        clientCertificatePath: String = "",
        clientCertificatePassword: String = ""
    ) {
        self.id = id
        self.name = name
        self.hostPatterns = hostPatterns
        self.caCertificatePath = caCertificatePath
        self.pinToCA = pinToCA
        self.allowLongValidity = allowLongValidity
        self.clientCertificatePath = clientCertificatePath
        self.clientCertificatePassword = clientCertificatePassword
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Yeni Profil",
            hostPatterns: try container.decodeIfPresent([String].self, forKey: .hostPatterns) ?? [],
            caCertificatePath: try container.decodeIfPresent(String.self, forKey: .caCertificatePath) ?? "",
            pinToCA: try container.decodeIfPresent(Bool.self, forKey: .pinToCA) ?? false,
            allowLongValidity: try container.decodeIfPresent(Bool.self, forKey: .allowLongValidity) ?? false,
            clientCertificatePath: try container.decodeIfPresent(String.self, forKey: .clientCertificatePath) ?? "",
            clientCertificatePassword: try container.decodeIfPresent(String.self, forKey: .clientCertificatePassword) ?? ""
        )
    }

    public var hasCA: Bool { !caCertificatePath.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Sabitleme işaretli ama sabitlenecek CA yok.
    ///
    /// Bu haliyle kutu bir güvenlik özelliği VAAT EDİYOR ama veremiyor:
    /// sabitlenecek çıpa olmadığı için doğrulama sistem köklerine düşer.
    /// Dahası, sabitleme açıkken kurum güven deposu bilinçli olarak devre
    /// dışı bırakıldığı için, CA'sı depodan gelen host'lar bu yüzden hata
    /// vermeye başlıyordu. Arayüz bunu engeller, motor da etkisiz sayar.
    public var pinsWithoutCA: Bool { pinToCA && !hasCA }

    /// Sabitleme gerçekten uygulanabiliyor mu.
    public var isPinningEffective: Bool { pinToCA && hasCA }

    public var hasClientCertificate: Bool {
        !clientCertificatePath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Profilde tanımlı ama geçersiz olan host kalıpları.
    public var invalidPatterns: [String] {
        hostPatterns.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !HostPattern.isValid($0) }
    }

    /// Profil hiçbir host'a uygulanamıyor: geçerli tek bir kalıbı yok.
    ///
    /// Sessiz bir tuzak: kullanıcı CA'yı seçiyor, seçenekleri işaretliyor,
    /// ama Host'lar listesi boş kalınca profil HİÇBİR ŞEY yapmıyor ve
    /// bunu söyleyen bir şey yok. Sahada tam olarak bu yaşandı.
    public var appliesToNothing: Bool {
        !hostPatterns.contains { HostPattern.isValid($0) }
    }

    public func applies(to host: String) -> Bool {
        HostPattern.matchesAny(hostPatterns, host: host)
    }

    /// Host için geçerli ilk profil. Birden fazla eşleşirse daha ÖZGÜL olan
    /// (jokersiz) kazanır; aksi halde geniş bir joker, özel bir kuralı ezerdi.
    public static func profile(for host: String, in profiles: [TLSProfile]) -> TLSProfile? {
        let matching = profiles.filter { $0.applies(to: host) }
        return matching.first { profile in
            profile.hostPatterns.contains { HostPattern.matches($0, host: host) && !$0.hasPrefix("*.") }
        } ?? matching.first
    }
}
