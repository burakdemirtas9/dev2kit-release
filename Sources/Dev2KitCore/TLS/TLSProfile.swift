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
        clientCertificatePath: String = "",
        clientCertificatePassword: String = ""
    ) {
        self.id = id
        self.name = name
        self.hostPatterns = hostPatterns
        self.caCertificatePath = caCertificatePath
        self.pinToCA = pinToCA
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
            clientCertificatePath: try container.decodeIfPresent(String.self, forKey: .clientCertificatePath) ?? "",
            clientCertificatePassword: try container.decodeIfPresent(String.self, forKey: .clientCertificatePassword) ?? ""
        )
    }

    public var hasCA: Bool { !caCertificatePath.trimmingCharacters(in: .whitespaces).isEmpty }
    public var hasClientCertificate: Bool {
        !clientCertificatePath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Profilde tanımlı ama geçersiz olan host kalıpları.
    public var invalidPatterns: [String] {
        hostPatterns.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !HostPattern.isValid($0) }
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
