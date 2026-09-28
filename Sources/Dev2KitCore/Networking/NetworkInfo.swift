import Foundation

/// Bağlantının teknik künyesi: hangi protokolle, nereye, hangi TLS ile bağlanıldı
/// ve sunucu hangi sertifikayı sundu.
///
/// Neden ayrı bir tip: bu bilgiler yanıtın kendisi değil, yanıtı GETİREN
/// bağlantının özelliği. "500 ms sürdü" ile "TLS 1.2 ile bağlandık, bağlantı
/// yeniden kullanıldı" farklı sorulara cevap verir. Kurum CA'sı ve mTLS
/// kullanan bir araçta ikincisi ayrıca doğrulama aracıdır: yapılandırdığın
/// profilin gerçekten devrede olduğunu burada görürsün.
///
/// Alanların hepsi opsiyonel: HTTP bağlantısında TLS alanları, ilk bağlantıda
/// "yeniden kullanıldı" bilgisi olmayabilir. Bilinmeyeni uydurmaktansa boş
/// bırakılır; arayüz de göstermez.
public struct NetworkInfo: Sendable, Equatable {
    public var httpVersion: String?
    public var localAddress: String?
    public var remoteAddress: String?
    public var tlsProtocol: String?
    public var cipherName: String?
    public var certificate: CertificateSummary?
    /// Bağlantı havuzdan mı geldi? El sıkışma maliyetinin neden görünmediğini açıklar.
    public var isReusedConnection: Bool?
    public var isProxyConnection: Bool?

    public init(
        httpVersion: String? = nil,
        localAddress: String? = nil,
        remoteAddress: String? = nil,
        tlsProtocol: String? = nil,
        cipherName: String? = nil,
        certificate: CertificateSummary? = nil,
        isReusedConnection: Bool? = nil,
        isProxyConnection: Bool? = nil
    ) {
        self.httpVersion = httpVersion
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.tlsProtocol = tlsProtocol
        self.cipherName = cipherName
        self.certificate = certificate
        self.isReusedConnection = isReusedConnection
        self.isProxyConnection = isProxyConnection
    }

    /// Gösterilecek hiçbir şey yoksa arayüz düğmeyi hiç açmaz.
    public var isEmpty: Bool {
        self == NetworkInfo()
    }

    // MARK: - Ham değerlerin okunabilir karşılıkları

    /// `tls_protocol_version_t` ham değeri → "TLS 1.3".
    /// Bilinmeyen değer gizlenmez, ham haliyle gösterilir: yanlış isim vermektense.
    public static func tlsProtocolName(_ raw: UInt16) -> String {
        switch raw {
        case 0x0301: return "TLS 1.0"
        case 0x0302: return "TLS 1.1"
        case 0x0303: return "TLS 1.2"
        case 0x0304: return "TLS 1.3"
        case 0xFEFF: return "DTLS 1.0"
        case 0xFEFD: return "DTLS 1.2"
        default: return String(format: "0x%04X", raw)
        }
    }

    /// `tls_ciphersuite_t` ham değeri → IANA adı.
    /// Apple'ın modern URLSession'da pazarlık ettiği takımlar listelendi;
    /// listede olmayan değer ham haliyle gösterilir.
    public static func cipherName(_ raw: UInt16) -> String {
        switch raw {
        // TLS 1.3
        case 0x1301: return "TLS_AES_128_GCM_SHA256"
        case 0x1302: return "TLS_AES_256_GCM_SHA384"
        case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256"
        // TLS 1.2 — ECDHE/RSA
        case 0xC02B: return "ECDHE_ECDSA_AES_128_GCM_SHA256"
        case 0xC02C: return "ECDHE_ECDSA_AES_256_GCM_SHA384"
        case 0xC02F: return "ECDHE_RSA_AES_128_GCM_SHA256"
        case 0xC030: return "ECDHE_RSA_AES_256_GCM_SHA384"
        case 0xCCA8: return "ECDHE_RSA_CHACHA20_POLY1305"
        case 0xCCA9: return "ECDHE_ECDSA_CHACHA20_POLY1305"
        case 0xC023: return "ECDHE_ECDSA_AES_128_CBC_SHA256"
        case 0xC027: return "ECDHE_RSA_AES_128_CBC_SHA256"
        case 0xC009: return "ECDHE_ECDSA_AES_128_CBC_SHA"
        case 0xC013: return "ECDHE_RSA_AES_128_CBC_SHA"
        case 0xC00A: return "ECDHE_ECDSA_AES_256_CBC_SHA"
        case 0xC014: return "ECDHE_RSA_AES_256_CBC_SHA"
        case 0x009C: return "RSA_AES_128_GCM_SHA256"
        case 0x009D: return "RSA_AES_256_GCM_SHA384"
        case 0x002F: return "RSA_AES_128_CBC_SHA"
        case 0x0035: return "RSA_AES_256_CBC_SHA"
        default: return String(format: "0x%04X", raw)
        }
    }

    /// "192.168.1.108:52341" — ikisi de yoksa nil.
    public static func address(host: String?, port: Int?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        guard let port, port > 0 else { return host }
        return "\(host):\(port)"
    }
}

/// Sunucunun sunduğu sertifikanın künyesi.
public struct CertificateSummary: Sendable, Equatable {
    public let commonName: String?
    public let issuerCommonName: String?
    public let validUntil: Date?

    public init(commonName: String?, issuerCommonName: String?, validUntil: Date?) {
        self.commonName = commonName
        self.issuerCommonName = issuerCommonName
        self.validUntil = validUntil
    }

    /// Süresi geçmiş bir sertifikayı kullanıcı görsün: bağlantı kurulmuş olsa
    /// bile (ör. kurum CA'sı zinciri) bu bilgi anlamlı.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let validUntil else { return false }
        return validUntil < now
    }
}
